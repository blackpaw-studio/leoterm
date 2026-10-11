import Foundation

/// What a read-only attach yields: the handshake completing, then the
/// session's terminal output as it arrives.
public enum LeoTerminalEvent: Equatable, Sendable {
    case opened
    case output(Data)
}

/// How an attach ended, beyond plain transport failures (`LeoDaemonError`).
public enum LeoTerminalAttachError: Error, Equatable, Sendable {
    /// The daemon closed the socket: 1008 on revoke (or input), 1000 when
    /// the tmux session ended, 1011 when tmux could not attach.
    case closed(code: Int, reason: String)
    /// The upgrade was answered with this HTTP status (404: unknown agent,
    /// 401/403: the token was refused).
    case rejected(status: Int)
    /// Nothing arrived for longer than the daemon's heartbeat allows.
    case idleTimeout

    public static let policyViolation = 1008
}

extension LeoTerminalAttachError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .closed(let code, let reason): reason.isEmpty ? "The daemon closed the terminal (\(code))." : "The daemon closed the terminal: \(reason)."
        case .rejected(let status): "The daemon refused the terminal (HTTP \(status))."
        case .idleTimeout: "The terminal stopped responding."
        }
    }
}

public enum LeoWebSocketMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

/// The socket under an attach: the system boundary, faked in tests.
/// Implementations map their own failures to `LeoTerminalAttachError` /
/// `LeoDaemonError` before throwing.
public protocol LeoWebSocket: Sendable {
    /// Starts the handshake and returns once the socket is open.
    func open() async throws
    func receive() async throws -> LeoWebSocketMessage
    func send(text: String) async throws
    /// Closes the socket; a pending `open`/`receive` throws.
    func cancel()
}

/// `GET /api/v1/agents/{name}/attach`: a read-only view of an agent's tmux
/// session. Nothing but JSON control frames (`pong`) is ever sent.
public enum LeoTerminalAttach {
    /// Comfortably past the daemon's 30 s heartbeat.
    public static let idleTimeout: Duration = .seconds(75)

    /// The upgrade request on the paired origin (https → wss, http → ws),
    /// with the bearer and any Cloudflare Access headers.
    public static func request(endpoint: LeoRemoteEndpoint, agent: String, cols: Int, rows: Int) throws -> URLRequest {
        let path = "/api/v1/agents/\(try LeoSocketDaemonClient.pathSegment(agent))/attach?cols=\(cols)&rows=\(rows)"
        var request = try LeoHTTPSTransport(endpoint: endpoint).urlRequest(for: LeoHTTPRequest(method: "GET", path: path), timeout: 30)
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LeoDaemonError.decoding("Invalid attach URL")
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw LeoDaemonError.decoding("Unsupported daemon URL scheme")
        }
        request.url = components.url
        return request
    }

    /// One attach over `socket`. Finishes by throwing how it ended; ending
    /// the stream early cancels the socket.
    public static func events(
        socket: any LeoWebSocket, idleTimeout: Duration = Self.idleTimeout, clock: any Clock<Duration> = ContinuousClock()
    ) -> AsyncThrowingStream<LeoTerminalEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await socket.open()
                    continuation.yield(.opened)
                    while true {
                        switch try await receive(socket, idleTimeout: idleTimeout, clock: clock) {
                        case .binary(let data):
                            continuation.yield(.output(data))
                        case .text(let text):
                            if Control.type(of: text) == "ping" { try await socket.send(text: Control.pong) }
                        }
                    }
                } catch {
                    socket.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                socket.cancel()
            }
        }
    }

    /// The next message, or `idleTimeout` (cancelling the socket so the
    /// pending receive returns) when none comes in time.
    private static func receive(_ socket: any LeoWebSocket, idleTimeout: Duration, clock: any Clock<Duration>) async throws -> LeoWebSocketMessage {
        try await withThrowingTaskGroup(of: LeoWebSocketMessage.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await clock.sleep(for: idleTimeout)
                socket.cancel()
                throw LeoTerminalAttachError.idleTimeout
            }
            defer { group.cancelAll() }
            do {
                guard let message = try await group.next() else { throw CancellationError() }
                return message
            } catch is CancellationError where !Task.isCancelled {
                // The watchdog cancelled the receive; report the timeout.
                throw LeoTerminalAttachError.idleTimeout
            }
        }
    }

    private enum Control {
        static let pong = #"{"type":"pong"}"#

        static func type(of text: String) -> String? {
            struct Frame: Decodable { let type: String }
            return (try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)))?.type
        }
    }
}
