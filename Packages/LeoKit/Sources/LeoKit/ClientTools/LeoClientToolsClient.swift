import Foundation
import OSLog

private var leoClientToolsLogger: Logger { LeoLog.logger() }

/// What a provider stream reports. `.request` is only ever a full request:
/// the redacted frames a non-provider stream gets are dropped (they exist so
/// `seq` stays contiguous).
public enum LeoClientToolsEvent: Equatable, Sendable {
    /// The daemon assigned this stream a client id; register tools now.
    case hello(clientID: String)
    case request(LeoClientToolRequest)
    /// The request timed out, the agent's call was cancelled, or the agent
    /// went away: abort it and dismiss any UI waiting on it.
    case cancelled(LeoClientToolCancellation)
    /// The daemon's tool set changed (`revision`, tool names).
    case changed(revision: Int, tools: [String])
    /// Frames were missed; the session should re-read `pending()`.
    case gap(expected: Int, received: Int)
    case disconnected(reason: String)
}

/// The app side of the daemon's client-tools relay over a daemon socket:
/// a provider event stream (`GET /events?client_tools=1`) plus the register,
/// claim, result and pending routes.
///
/// One stream per `events()` call and no reconnect of its own (D-061): when
/// the stream ends it yields `.disconnected` and finishes, and the session
/// owns retry. The client id from the stream's `hello` is held for the calls
/// until that stream ends; calls outside a live stream throw
/// `LeoClientToolsError.unknownClient`.
public actor LeoClientToolsClient {
    /// The `.disconnected` reason when the daemon's hello carries no client id
    /// (it predates client tools and ignored `?client_tools=1`).
    public static let unsupportedReason = "Daemon does not support client tools"

    static let root = "/api/v1/client-tools"
    static let providerStreamPath = "/events?client_tools=1"
    private static let idCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    private let socketPath: String
    private let transport: any LeoSocketActivityTransport
    private let callTimeout: TimeInterval
    private var generation = 0
    public private(set) var clientID: String?

    public init(socketPath: String, transport: any LeoSocketActivityTransport, callTimeout: TimeInterval = 10) {
        self.socketPath = socketPath
        self.transport = transport
        self.callTimeout = callTimeout
    }

    // MARK: - Stream

    public func events() -> AsyncStream<LeoClientToolsEvent> {
        generation += 1
        let generation = generation
        return AsyncStream { continuation in
            let task = Task { await self.run(generation: generation, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(generation: Int, _ continuation: AsyncStream<LeoClientToolsEvent>.Continuation) async {
        defer {
            if self.generation == generation { clientID = nil }
            continuation.finish()
        }
        var lastSequence: Int?
        var parser = LeoSSEParser()
        var reason = LeoSocketActivityClient.closedReason
        leoClientToolsLogger.log("clientTools: connecting socketPath=\(self.socketPath, privacy: .public)")
        do {
            for try await bytes in transport.stream(path: Self.providerStreamPath, socketPath: socketPath, idleTimeout: 60) {
                for raw in parser.feed(bytes) {
                    guard let event = LeoClientToolsWireEvent.decode(raw) else { continue }
                    if let lastSequence, event.sequence > lastSequence + 1 {
                        continuation.yield(.gap(expected: lastSequence + 1, received: event.sequence))
                    }
                    lastSequence = event.sequence
                    guard let mapped = map(event, generation: generation) else { continue }
                    if case .disconnected(let because) = mapped {
                        reason = because
                        continuation.yield(mapped)
                        return
                    }
                    continuation.yield(mapped)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            reason = Self.reason(for: error)
        }
        guard !Task.isCancelled else { return }
        leoClientToolsLogger.log("clientTools: disconnected reason=\(reason, privacy: .public)")
        continuation.yield(.disconnected(reason: reason))
    }

    private func map(_ event: LeoClientToolsWireEvent, generation: Int) -> LeoClientToolsEvent? {
        switch event {
        case .hello(_, let id?, _):
            if self.generation == generation { clientID = id }
            return .hello(clientID: id)
        case .hello:
            return .disconnected(reason: Self.unsupportedReason)
        case .changed(_, let revision, let tools):
            return .changed(revision: revision, tools: tools)
        case .request(_, .full(let request)):
            return .request(request)
        case .request(_, .redacted):
            return nil
        case .cancelled(_, let cancellation):
            return .cancelled(cancellation)
        case .other:
            return nil
        }
    }

    private static func reason(for error: Error) -> String {
        guard let error = error as? LeoDaemonError else { return String(describing: error) }
        if case .transport(let reason) = error { return reason }
        return String(describing: error)
    }

    // MARK: - Routes

    /// Registers (or replaces) this client's `group`; the daemon's tool-set revision.
    public func register(group: String, tools: [LeoClientToolDefinition]) async throws -> Int {
        let body = LeoClientToolsRegisterRequest(clientID: try requireClientID(), group: group, tools: tools)
        let registered: LeoClientToolsRegistered = try await send("POST", Self.root, body: body)
        return registered.revision
    }

    /// Claims a request so this client alone may answer it. Throws `.ownedByOther`
    /// / `.alreadyClaimed` (409) or `.unknownRequest` (404, also once settled).
    public func claim(_ requestID: String) async throws -> LeoClientToolRequest {
        let body = LeoClientToolClaimRequest(clientID: try requireClientID())
        let claimed: LeoClientToolClaimed = try await send("POST", try Self.requestPath(requestID, "claim"), body: body)
        return claimed.request
    }

    /// Settles a claimed request. Throws `.notClaimant` / `.alreadySettled` (409)
    /// or `.unknownRequest` (404).
    public func postResult(_ requestID: String, _ outcome: LeoClientToolOutcome) async throws {
        let body = LeoClientToolResultRequest(clientID: try requireClientID(), outcome: outcome)
        let _: LeoClientToolEmpty = try await send("POST", try Self.requestPath(requestID, "result"), body: body)
    }

    /// Every unsettled request, claimed or not, for recovery after a reconnect or `.gap`.
    public func pending() async throws -> [LeoClientToolPending] {
        _ = try requireClientID()
        let list: LeoClientToolPendingList = try await send("GET", "\(Self.root)/requests?pending=1", body: nil as LeoClientToolEmpty?)
        return list.requests
    }

    // MARK: - Plumbing

    private func requireClientID() throws -> String {
        guard let clientID else { throw LeoClientToolsError.unknownClient(message: "No provider stream is open") }
        return clientID
    }

    private static func requestPath(_ requestID: String, _ action: String) throws -> String {
        guard !requestID.isEmpty, let escaped = requestID.addingPercentEncoding(withAllowedCharacters: idCharacters) else {
            throw LeoClientToolsError.unknownRequest(message: "Invalid request id")
        }
        return "\(root)/requests/\(escaped)/\(action)"
    }

    private func send<Response: Decodable & Sendable>(_ method: String, _ path: String, body: (some Encodable)?) async throws -> Response {
        let encoded = try body.map { try JSONEncoder().encode($0) }
        let response = try await transport.send(LeoHTTPRequest(method: method, path: path, body: encoded), socketPath: socketPath, timeout: callTimeout)
        guard let envelope = try? LeoDaemonEnvelope<Response>.decode(response.body) else {
            throw LeoDaemonError.transport("Client tools endpoint returned HTTP \(response.status)")
        }
        guard envelope.ok else { throw LeoClientToolsError(envelope: envelope, rawBody: response.body) }
        return try envelope.value()
    }
}
