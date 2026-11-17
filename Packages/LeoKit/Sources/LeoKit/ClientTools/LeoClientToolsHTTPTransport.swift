import Foundation

/// Where a `LeoClientToolsClient` opens its provider stream and sends its
/// route calls: the daemon's socket on the Mac, a paired daemon's HTTPS API
/// on iOS. Paths are the daemon's `/api/v1/client-tools` routes on both.
public protocol LeoClientToolsTransport: Sendable {
    /// Names the daemon in logs. Never carries a credential.
    var logTarget: String { get }
    /// The provider event stream (`?client_tools=1`), parsed into SSE events.
    func providerEvents() -> AsyncThrowingStream<LeoSSEEvent, any Error>
    func send(_ request: LeoHTTPRequest, timeout: TimeInterval) async throws -> LeoHTTPResponse
}

/// The Mac's transport: the daemon's unix socket, unauthenticated (0600).
public struct LeoClientToolsSocketTransport: LeoClientToolsTransport {
    static let providerStreamPath = "/events?client_tools=1"
    static let idleTimeout: TimeInterval = 60

    public let socketPath: String
    private let transport: any LeoSocketActivityTransport

    public init(socketPath: String, transport: any LeoSocketActivityTransport) {
        self.socketPath = socketPath
        self.transport = transport
    }

    public var logTarget: String { "socket \(socketPath)" }

    public func providerEvents() -> AsyncThrowingStream<LeoSSEEvent, any Error> {
        let bytes = transport.stream(path: Self.providerStreamPath, socketPath: socketPath, idleTimeout: Self.idleTimeout)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = LeoSSEParser()
                do {
                    for try await chunk in bytes {
                        parser.feed(chunk).forEach { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ request: LeoHTTPRequest, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        try await transport.send(request, socketPath: socketPath, timeout: timeout)
    }
}

/// iOS's transport: a paired daemon's web API. The device token rides as
/// the bearer (the daemon lets paired devices open provider streams), with
/// the Cloudflare Access headers when the pairing has them.
public struct LeoClientToolsHTTPTransport: LeoClientToolsTransport {
    static let providerStreamPath = "/api/v1/events?client_tools=1"

    private let web: any LeoWebTransport
    public let logTarget: String

    public init(endpoint: LeoRemoteEndpoint, session: URLSession = .shared) {
        self.init(web: LeoHTTPSTransport(endpoint: endpoint, session: session), logTarget: endpoint.baseURL.host() ?? "daemon")
    }

    public init(web: any LeoWebTransport, logTarget: String) {
        self.web = web
        self.logTarget = logTarget
    }

    public func providerEvents() -> AsyncThrowingStream<LeoSSEEvent, any Error> {
        web.events(path: Self.providerStreamPath)
    }

    public func send(_ request: LeoHTTPRequest, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        try await web.send(request, timeout: timeout)
    }
}
