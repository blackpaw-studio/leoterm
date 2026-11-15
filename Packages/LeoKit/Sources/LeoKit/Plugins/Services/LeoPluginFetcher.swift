import Foundation
import OSLog

/// How `LeoPluginFetchResponse.body` carries the response bytes.
public enum LeoPluginFetchBodyEncoding: String, Equatable, Sendable {
    /// The body is the text itself.
    case utf8
    /// The bytes aren't valid UTF-8 (an image, say); the body is their base64.
    case base64
}

public struct LeoPluginFetchResponse: Equatable, Sendable {
    public let status: Int
    /// Header names lowercased, like the web `Headers` API.
    public let headers: [String: String]
    public let body: String
    public let bodyEncoding: LeoPluginFetchBodyEncoding

    public init(status: Int, headers: [String: String], body: String, bodyEncoding: LeoPluginFetchBodyEncoding = .utf8) {
        self.status = status
        self.headers = headers
        self.body = body
        self.bodyEncoding = bodyEncoding
    }

    /// Text when `data` is valid UTF-8, base64 otherwise, so no byte is altered.
    init(status: Int, headers: [String: String], data: Data) {
        if let text = String(data: data, encoding: .utf8) {
            self.init(status: status, headers: headers, body: text, bodyEncoding: .utf8)
        } else {
            self.init(status: status, headers: headers, body: data.base64EncodedString(), bodyEncoding: .base64)
        }
    }

    /// What the plugin's `leo.fetch` promise resolves to: `{status, headers, body, bodyEncoding}`.
    public var replyValue: LeoJSONValue {
        .object([
            "status": .int(status),
            "headers": .object(headers.mapValues { .string($0) }),
            "body": .string(body),
            "bodyEncoding": .string(bodyEncoding.rawValue),
        ])
    }
}

/// Why a plugin's `leo.fetch` was rejected. `reason` goes back to the plugin
/// as the rejected promise's message.
public enum LeoPluginFetchError: Error, Equatable, LocalizedError, Sendable {
    case denied(String)
    case invalidRequest(String)
    case rateLimited(retryAfter: TimeInterval)
    case tooManyInFlight
    case bodyTooLarge(limit: Int)
    case network(String)

    public var reason: String {
        switch self {
        case .denied(let reason): reason
        case .invalidRequest(let reason): "invalid fetch request: \(reason)"
        case .rateLimited(let retryAfter): "rate limited: retry in \(Int(retryAfter.rounded(.up))) s"
        case .tooManyInFlight: "too many requests in flight (limit \(LeoPluginRateLimiter.defaultMaxInFlight))"
        case .bodyTooLarge(let limit): "response body is larger than \(limit / 1024 / 1024) MB"
        case .network(let reason): "network error: \(reason)"
        }
    }

    public var errorDescription: String? { reason }
}

/// What the router needs from a fetcher, so it can be faked.
public protocol LeoPluginFetching: Sendable {
    func fetch(url: String, init options: LeoPluginFetchInit) async throws -> LeoPluginFetchResponse
}

extension LeoPluginFetcher: LeoPluginFetching {}

/// `leo.fetch` for one plugin. The app performs the request on the plugin's
/// behalf, so everything is checked here: the manifest's hosts on the first
/// URL *and every redirect hop*, https only, the per-plugin rate limit, and a
/// 5 MB cap on the streamed body. Each call uses its own ephemeral session
/// with no cookies, credentials or cache.
public final class LeoPluginFetcher: Sendable {
    public static let maxBodyBytes = 5 * 1024 * 1024
    static let requestTimeout: TimeInterval = 30
    static let allowedMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
    static let bodylessMethods: Set<String> = ["GET", "HEAD"]
    /// Set by the app or the transport, never by plugin code.
    static let forbiddenHeaders: Set<String> = [
        "host", "cookie", "cookie2", "content-length", "transfer-encoding", "connection", "upgrade", "te", "expect",
        "keep-alive", "proxy-connection",
    ]
    /// Dropped when a redirect changes host, so a credential never follows it.
    static let credentialHeaders = ["Authorization", "Cookie", "Proxy-Authorization"]
    static let maxHeaderCount = 50
    static let maxHeaderValueBytes = 8 * 1024

    private let pluginID: String
    private let engine: LeoPluginPermissionEngine
    private let limiter: LeoPluginRateLimiter
    private let configure: @Sendable (URLSessionConfiguration) -> Void

    /// `configure` adjusts the session configuration; tests install a stub protocol there.
    public init(
        pluginID: String, engine: LeoPluginPermissionEngine, limiter: LeoPluginRateLimiter = LeoPluginRateLimiter(),
        configure: @escaping @Sendable (URLSessionConfiguration) -> Void = { _ in }
    ) {
        self.pluginID = pluginID
        self.engine = engine
        self.limiter = limiter
        self.configure = configure
    }

    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.waitsForConnectivity = false
        return configuration
    }

    public func fetch(url: String, init options: LeoPluginFetchInit) async throws -> LeoPluginFetchResponse {
        do {
            return try await perform(url: url, options: options)
        } catch {
            LeoLog.logger(category: "leo.plugins").warning(
                "fetch rejected for \(self.pluginID, privacy: .public) (\(Self.loggableHost(url), privacy: .public)): \((error as? LeoPluginFetchError)?.reason ?? error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    private func perform(url: String, options: LeoPluginFetchInit) async throws -> LeoPluginFetchResponse {
        guard let given = URL(string: url) else { throw LeoPluginFetchError.invalidRequest("not a valid URL") }
        if case .denied(let reason) = engine.check(url: given, hop: 0) { throw LeoPluginFetchError.denied(reason) }
        guard let parsed = Self.canonicalURL(given) else { throw LeoPluginFetchError.invalidRequest("not a valid URL") }
        let request = try Self.makeRequest(url: parsed, options: options)

        // Only requests that passed every check spend quota.
        let permit: LeoPluginRateLimitPermit
        switch limiter.acquire() {
        case .granted(let granted): permit = granted
        case .rejected(.rateLimited(let retryAfter)): throw LeoPluginFetchError.rateLimited(retryAfter: retryAfter)
        case .rejected(.tooManyInFlight): throw LeoPluginFetchError.tooManyInFlight
        }
        defer { limiter.release(permit) }

        let configuration = Self.sessionConfiguration()
        configure(configuration)
        let transfer = LeoPluginFetchTransfer(engine: engine, originHost: LeoPluginPermissionEngine.canonicalHost(of: parsed), maxBytes: Self.maxBodyBytes)
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.begin(task: task, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    // MARK: - Request

    /// `url` rewritten so its host is exactly `LeoPluginPermissionEngine.canonicalHost(of:)`:
    /// the host that was checked is the host that gets contacted. Nil if there is no canonical host.
    static func canonicalURL(_ url: URL) -> URL? {
        guard let host = LeoPluginPermissionEngine.canonicalHost(of: url) else { return nil }
        let absolute = url.absoluteString
        guard let schemeEnd = absolute.range(of: "://") else { return nil }
        let rest = absolute[schemeEnd.upperBound...]
        let authority = rest.prefix { !"/?#".contains($0) }
        let port = authority.firstIndex(of: ":").map { String(authority[$0...]) } ?? ""
        let tail = rest.dropFirst(authority.count)
        return URL(string: "\(absolute[..<schemeEnd.upperBound])\(host)\(port)\(tail)")
    }

    static func makeRequest(url: URL, options: LeoPluginFetchInit) throws -> URLRequest {
        let method = (options.method ?? "GET").uppercased()
        guard allowedMethods.contains(method) else { throw LeoPluginFetchError.invalidRequest("method \(method) is not allowed") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.httpShouldHandleCookies = false
        let headers = options.headers ?? [:]
        guard headers.count <= maxHeaderCount else { throw LeoPluginFetchError.invalidRequest("too many headers") }
        for (name, value) in headers {
            try validateHeader(name: name, value: value)
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = options.body {
            guard !bodylessMethods.contains(method) else { throw LeoPluginFetchError.invalidRequest("\(method) requests can't have a body") }
            let data = Data(body.utf8)
            guard data.count <= maxBodyBytes else { throw LeoPluginFetchError.invalidRequest("request body is too large") }
            request.httpBody = data
        }
        return request
    }

    private static func validateHeader(name: String, value: String) throws {
        let lower = name.lowercased()
        guard !name.isEmpty, name.utf8.allSatisfy(isTokenByte) else {
            throw LeoPluginFetchError.invalidRequest("header name '\(name)' is not valid")
        }
        guard !forbiddenHeaders.contains(lower), !lower.hasPrefix("proxy-") else {
            throw LeoPluginFetchError.invalidRequest("header '\(name)' can't be set by a plugin")
        }
        guard value.utf8.count <= maxHeaderValueBytes, !value.utf8.contains(where: { $0 == 0x0D || $0 == 0x0A || $0 == 0 }) else {
            throw LeoPluginFetchError.invalidRequest("value of header '\(name)' is not valid")
        }
    }

    /// RFC 9110 token characters.
    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }

    /// The host alone: query strings can carry tokens.
    private static func loggableHost(_ url: String) -> String {
        URL(string: url)?.host ?? "?"
    }
}

/// One request's delegate: re-checks every redirect hop and streams the body
/// under a byte cap. Finishes exactly once.
private final class LeoPluginFetchTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let engine: LeoPluginPermissionEngine
    private let originHost: String?
    private let maxBytes: Int

    private let lock = NSLock()
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<LeoPluginFetchResponse, Error>?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var hop = 0
    private var finished = false

    init(engine: LeoPluginPermissionEngine, originHost: String?, maxBytes: Int) {
        self.engine = engine
        self.originHost = originHost
        self.maxBytes = maxBytes
    }

    func begin(task: URLSessionTask, continuation: CheckedContinuation<LeoPluginFetchResponse, Error>) {
        let alreadyCancelled = lock.withLock { () -> Bool in
            self.task = task
            if !finished { self.continuation = continuation }
            return finished
        }
        // The caller's task was cancelled before the request started.
        if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    // MARK: - Delegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let nextHop = lock.withLock { () -> Int in
            hop += 1
            return hop
        }
        guard let url = request.url else {
            finish(.failure(LeoPluginFetchError.denied("redirect hop \(nextHop): no target URL")))
            return completionHandler(nil)
        }
        if case .denied(let reason) = engine.check(url: url, hop: nextHop) {
            finish(.failure(LeoPluginFetchError.denied(reason)))
            return completionHandler(nil)
        }
        guard let canonical = LeoPluginFetcher.canonicalURL(url) else {
            finish(.failure(LeoPluginFetchError.denied("redirect hop \(nextHop): no canonical host")))
            return completionHandler(nil)
        }
        var redirected = request
        redirected.url = canonical
        if LeoPluginPermissionEngine.canonicalHost(of: canonical) != originHost {
            for header in LeoPluginFetcher.credentialHeaders { redirected.setValue(nil, forHTTPHeaderField: header) }
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(LeoPluginFetchError.network("the response was not HTTP")))
            return completionHandler(.cancel)
        }
        if http.expectedContentLength > Int64(maxBytes) {
            finish(.failure(LeoPluginFetchError.bodyTooLarge(limit: maxBytes)))
            return completionHandler(.cancel)
        }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock { () -> Bool in
            guard !finished else { return false }
            guard body.count + data.count <= maxBytes else { return true }
            body.append(data)
            return false
        }
        if overflow { finish(.failure(LeoPluginFetchError.bodyTooLarge(limit: maxBytes))) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(LeoPluginFetchError.network((error as? URLError)?.localizedDescription ?? error.localizedDescription)))
            return
        }
        let (http, data) = lock.withLock { (response, body) }
        guard let http else {
            finish(.failure(LeoPluginFetchError.network("no response")))
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        finish(.success(LeoPluginFetchResponse(status: http.statusCode, headers: headers, data: data)))
    }

    // MARK: - Completion

    private func finish(_ result: Result<LeoPluginFetchResponse, Error>) {
        let (continuation, task) = lock.withLock { () -> (CheckedContinuation<LeoPluginFetchResponse, Error>?, URLSessionTask?) in
            guard !finished else { return (nil, nil) }
            finished = true
            defer { self.continuation = nil }
            return (self.continuation, self.task)
        }
        guard let continuation else { return }
        if case .failure = result { task?.cancel() }
        continuation.resume(with: result)
    }
}
