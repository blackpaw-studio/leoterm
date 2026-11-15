import Foundation

/// `LeoWebSocket` over `URLSessionWebSocketTask`. The upgrade carries the
/// request's credentials and follows redirects only within its own origin,
/// the same guard as `LeoHTTPSTransport`, so the bearer and Access headers
/// never leave the paired daemon.
public final class LeoURLSessionWebSocket: NSObject, LeoWebSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Above the daemon's 32 KiB output frames.
    static let maximumMessageSize = 1 << 20

    private let task: URLSessionWebSocketTask
    private let redirects: SameOriginRedirects
    private let lock = NSLock()
    private var opening: CheckedContinuation<Void, any Error>?
    private var closed: (code: Int, reason: String)?

    public init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        redirects = SameOriginRedirects(
            origin: request.url ?? URL(fileURLWithPath: "/"), authorization: request.value(forHTTPHeaderField: "Authorization")
        )
        super.init()
        task.maximumMessageSize = Self.maximumMessageSize
        task.delegate = self
    }

    /// One attach to `agent` over a fresh socket.
    public static func attach(
        endpoint: LeoRemoteEndpoint, agent: String, cols: Int, rows: Int, session: URLSession = .shared
    ) -> AsyncThrowingStream<LeoTerminalEvent, any Error> {
        do {
            let request = try LeoTerminalAttach.request(endpoint: endpoint, agent: agent, cols: cols, rows: rows)
            return LeoTerminalAttach.events(socket: LeoURLSessionWebSocket(request: request, session: session))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock { opening = continuation }
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    public func receive() async throws -> LeoWebSocketMessage {
        do {
            switch try await withTaskCancellationHandler(operation: { try await task.receive() }, onCancel: { cancel() }) {
            case .data(let data): return .binary(data)
            case .string(let text): return .text(text)
            @unknown default: throw LeoDaemonError.decoding("Unknown WebSocket message")
            }
        } catch {
            throw failure(error)
        }
    }

    public func send(text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw failure(error)
        }
    }

    public func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }

    /// The most specific reason the socket failed: a refused redirect, the
    /// daemon's close frame, a non-101 upgrade status, then the transport.
    private func failure(_ error: any Error) -> any Error {
        do { try redirects.checkNoneRefused() } catch { return error }
        if let closed = lock.withLock({ closed }) { return LeoTerminalAttachError.closed(code: closed.code, reason: closed.reason) }
        if task.closeCode != .invalid {
            return LeoTerminalAttachError.closed(code: task.closeCode.rawValue, reason: task.closeReason.flatMap { String(bytes: $0, encoding: .utf8) } ?? "")
        }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
            return LeoTerminalAttachError.rejected(status: status)
        }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .timedOut: return LeoDaemonError.timeout
        default: return LeoDaemonError.transport(urlError.localizedDescription)
        }
    }

    private func finishOpening(_ result: Result<Void, any Error>) {
        let continuation = lock.withLock {
            defer { opening = nil }
            return opening
        }
        continuation?.resume(with: result)
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        finishOpening(.success(()))
    }

    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        lock.withLock { closed = (closeCode.rawValue, reason.flatMap { String(bytes: $0, encoding: .utf8) } ?? "") }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finishOpening(.failure(failure(error ?? URLError(.networkConnectionLost))))
    }

    // The completion-handler form: the async one crashes SILGen (Swift 6.2/6.3).
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        redirects.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
}
