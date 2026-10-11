import Foundation

/// A Cloudflare Access service token, sent as the `CF-Access-Client-Id` /
/// `CF-Access-Client-Secret` headers to a daemon behind Access.
public struct LeoCFAccessCredentials: Codable, Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

/// Where a daemon's web listener is and how to authenticate to it. `token`
/// is nil only for the unauthenticated pairing request.
public struct LeoRemoteEndpoint: Equatable, Sendable {
    public let baseURL: URL
    public let token: String?
    public let cfAccess: LeoCFAccessCredentials?

    public init(baseURL: URL, token: String?, cfAccess: LeoCFAccessCredentials? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.cfAccess = cfAccess
    }
}

/// Request/response plus SSE against one daemon's web listener.
public protocol LeoWebTransport: Sendable {
    /// Any HTTP status is a response; only a failure to get one throws.
    func send(_ request: LeoHTTPRequest, timeout: TimeInterval) async throws -> LeoHTTPResponse
    /// One SSE connection. Finishes when the server closes it; throws on a
    /// non-2xx status or a dropped connection. No reconnect of its own.
    func events(path: String) -> AsyncThrowingStream<LeoSSEEvent, any Error>
}

/// `LeoWebTransport` over URLSession (HTTPS, or plain HTTP on a LAN).
public struct LeoHTTPSTransport: LeoWebTransport {
    /// How long an SSE connection may go without a byte. The daemon sends a
    /// heartbeat well inside this.
    public static let streamIdleTimeout: TimeInterval = 90

    public let endpoint: LeoRemoteEndpoint
    private let session: URLSession

    public init(endpoint: LeoRemoteEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func urlRequest(for request: LeoHTTPRequest, timeout: TimeInterval) throws -> URLRequest {
        let base = endpoint.baseURL.absoluteString
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed + request.path) else {
            throw LeoDaemonError.decoding("Invalid request path \(request.path)")
        }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        if let token = endpoint.token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let access = endpoint.cfAccess {
            urlRequest.setValue(access.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
            urlRequest.setValue(access.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    public func send(_ request: LeoHTTPRequest, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        let urlRequest = try urlRequest(for: request, timeout: timeout)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return LeoHTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch let error as URLError {
            throw Self.transportError(error)
        }
    }

    public func events(path: String) -> AsyncThrowingStream<LeoSSEEvent, any Error> {
        let request: URLRequest
        do {
            var built = try urlRequest(for: LeoHTTPRequest(method: "GET", path: path), timeout: Self.streamIdleTimeout)
            built.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request = built
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        throw LeoDaemonError.daemon(
                            code: LeoSocketDaemonClient.controlCode(forStatus: status), message: "HTTP \(status)", matches: []
                        )
                    }
                    var parser = LeoSSEParser()
                    var line = Data()
                    for try await byte in bytes {
                        line.append(byte)
                        guard byte == 0x0A else { continue }
                        for event in parser.feed(line) { continuation.yield(event) }
                        line.removeAll(keepingCapacity: true)
                    }
                    for event in parser.feed(line + Data("\n\n".utf8)) { continuation.yield(event) }
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: Self.transportError(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func transportError(_ error: URLError) -> Error {
        if error.code == .cancelled { return CancellationError() }
        if error.code == .timedOut { return LeoDaemonError.timeout }
        return LeoDaemonError.transport(error.localizedDescription)
    }
}
