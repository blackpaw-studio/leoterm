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
    /// The account's own machine refused or failed the request. `code` is one of the plugin-facing
    /// `credential…` reasons; `message` never holds token bytes.
    case credentialRemote(code: String, message: String)
    /// The account's machine couldn't be asked: offline, too old, or not connected.
    case credentialMachineUnavailable(String)
    /// A credential fetch (or one of its redirects) went to a host other than the kind's bound host.
    case credentialHostMismatch(host: String)
    /// The plugin set a header that the credential injects.
    case credentialHeaderConflict(name: String)

    public var reason: String {
        switch self {
        case .denied(let reason): reason
        case .invalidRequest(let reason): "invalid fetch request: \(reason)"
        case .rateLimited(let retryAfter): "rate limited: retry in \(Int(retryAfter.rounded(.up))) s"
        case .tooManyInFlight: "too many requests in flight (limit \(LeoPluginRateLimiter.defaultMaxInFlight))"
        case .bodyTooLarge(let limit): "response body is larger than \(limit / 1024 / 1024) MB"
        case .network(let reason): "network error: \(reason)"
        case .credentialRemote(let code, let message): "\(code): \(message)"
        case .credentialMachineUnavailable(let message): "credentialMachineUnavailable: \(message)"
        case .credentialHostMismatch(let host): "credentialHostMismatch: '\(host)' is not this account's host"
        case .credentialHeaderConflict(let name): "credentialHeaderConflict: header '\(name)' is set by the account credential"
        }
    }

    public var errorDescription: String? { reason }
}

/// An account's headers, read only when a fetch is about to go out: after the
/// URL, host and headers passed every check and the rate limiter admitted it,
/// so a plugin can't turn rejected or over-rate fetches into Keychain reads.
public struct LeoPluginFetchCredentialSource: Sendable {
    /// Known before the read; the request must go to exactly this host.
    public let boundHost: String
    let resolve: @Sendable () async throws -> LeoPluginFetchCredential
    /// Set for an account on another machine: that machine's daemon reads the
    /// token and makes the request, so `resolve` is never called on this Mac.
    let remote: Remote?

    /// The machine-side half of a fetch: what the daemon injects, and how to reach it.
    struct Remote: Sendable {
        /// Lowercased header names the daemon sets itself; a plugin may not.
        let reservedHeaders: Set<String>
        let forward: @Sendable (LeoPluginRemoteFetchRequest) async throws -> LeoPluginFetchResponse
    }

    public init(boundHost: String, resolve: @escaping @Sendable () async throws -> LeoPluginFetchCredential) {
        self.boundHost = boundHost
        self.resolve = resolve
        self.remote = nil
    }

    public static func resolved(_ credential: LeoPluginFetchCredential) -> Self {
        Self(boundHost: credential.boundHost) { credential }
    }

    /// An account on another machine. Every check still runs here first; `forward`
    /// only ever sees a request that passed them.
    public static func remote(
        boundHost: String, reservedHeaders: Set<String>,
        forward: @escaping @Sendable (LeoPluginRemoteFetchRequest) async throws -> LeoPluginFetchResponse
    ) -> Self {
        Self(boundHost: boundHost, remote: Remote(reservedHeaders: reservedHeaders, forward: forward))
    }

    private init(boundHost: String, remote: Remote) {
        self.boundHost = boundHost
        self.remote = remote
        self.resolve = { throw LeoPluginFetchError.credentialMachineUnavailable("this account's token is not on this Mac") }
    }
}

/// A fetch that passed every check, ready for the account's machine.
public struct LeoPluginRemoteFetchRequest: Equatable, Sendable {
    public let url: String
    public let method: String
    public let headers: [LeoCredentialHeader]
    public let body: Data?

    public init(url: String, method: String, headers: [LeoCredentialHeader], body: Data?) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// What the router needs from a fetcher, so it can be faked.
public protocol LeoPluginFetching: Sendable {
    /// With a `credential`, its headers are injected and every hop must be its bound host.
    func fetch(url: String, init options: LeoPluginFetchInit, credential: LeoPluginFetchCredentialSource?) async throws -> LeoPluginFetchResponse
}

extension LeoPluginFetching {
    public func fetch(url: String, init options: LeoPluginFetchInit) async throws -> LeoPluginFetchResponse {
        try await fetch(url: url, init: options, credential: nil)
    }
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
    /// Headers a plugin may not set on a credential fetch (lowercased): the
    /// host injects them, and a plugin value must never replace an account's.
    static let credentialReservedHeaders: Set<String> = ["authorization", "chatgpt-account-id", "anthropic-beta"]
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

    public func fetch(url: String, init options: LeoPluginFetchInit, credential: LeoPluginFetchCredentialSource?) async throws -> LeoPluginFetchResponse {
        do {
            return try await perform(url: url, options: options, credential: credential)
        } catch {
            LeoLog.logger(category: "leo.plugins").warning(
                "fetch rejected for \(self.pluginID, privacy: .public) (\(Self.loggableHost(url), privacy: .public)): \((error as? LeoPluginFetchError)?.reason ?? error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    private func perform(url: String, options: LeoPluginFetchInit, credential source: LeoPluginFetchCredentialSource?) async throws -> LeoPluginFetchResponse {
        guard let given = URL(string: url) else { throw LeoPluginFetchError.invalidRequest("not a valid URL") }
        if case .denied(let reason) = engine.check(url: given, hop: 0) { throw LeoPluginFetchError.denied(reason) }
        guard let parsed = Self.canonicalURL(given) else { throw LeoPluginFetchError.invalidRequest("not a valid URL") }
        let originHost = LeoPluginPermissionEngine.canonicalHost(of: parsed)
        if let source, originHost != source.boundHost {
            throw LeoPluginFetchError.credentialHostMismatch(host: originHost ?? "?")
        }
        var request = try Self.makeRequest(url: parsed, options: options, reservesCredentialHeaders: source != nil)
        if let remote = source?.remote {
            try Self.rejectReserved(remote.reservedHeaders, in: options.headers ?? [:])
        }

        // Only requests that passed every check spend quota.
        let permit: LeoPluginRateLimitPermit
        switch limiter.acquire() {
        case .granted(let granted): permit = granted
        case .rejected(.rateLimited(let retryAfter)): throw LeoPluginFetchError.rateLimited(retryAfter: retryAfter)
        case .rejected(.tooManyInFlight): throw LeoPluginFetchError.tooManyInFlight
        }
        defer { limiter.release(permit) }

        // A remote account's token is read on its own machine, never here.
        if let remote = source?.remote {
            return try await remote.forward(Self.remoteRequest(request))
        }

        // Last: the account is read only for a request that is going out.
        var credential: LeoPluginFetchCredential?
        if let source {
            let resolved = try await source.resolve()
            guard resolved.boundHost == source.boundHost else {
                throw LeoPluginFetchError.credentialHostMismatch(host: originHost ?? "?")
            }
            try Self.inject(resolved, into: &request, pluginHeaders: options.headers ?? [:])
            credential = resolved
        }

        let configuration = Self.sessionConfiguration()
        configure(configuration)
        let transfer = LeoPluginFetchTransfer(engine: engine, originHost: originHost, credential: credential, maxBytes: Self.maxBodyBytes)
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

    /// Validates the plugin's part of the request. With `reservesCredentialHeaders`,
    /// headers an account credential sets are refused here, before any read.
    static func makeRequest(url: URL, options: LeoPluginFetchInit, reservesCredentialHeaders: Bool = false) throws -> URLRequest {
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
            if reservesCredentialHeaders, credentialReservedHeaders.contains(name.lowercased()) {
                throw LeoPluginFetchError.credentialHeaderConflict(name: name)
            }
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

    /// Adds the account's headers. A plugin header the credential also sets is refused, never overridden silently.
    static func inject(_ credential: LeoPluginFetchCredential, into request: inout URLRequest, pluginHeaders: [String: String]) throws {
        let injected = Set(credential.headers.keys.map { $0.lowercased() })
        if let clash = pluginHeaders.keys.first(where: { injected.contains($0.lowercased()) }) {
            throw LeoPluginFetchError.credentialHeaderConflict(name: clash)
        }
        for (name, value) in credential.headers { request.setValue(value, forHTTPHeaderField: name) }
    }

    /// A plugin header the daemon sets itself is refused, never overridden silently.
    static func rejectReserved(_ reserved: Set<String>, in pluginHeaders: [String: String]) throws {
        if let clash = pluginHeaders.keys.sorted().first(where: { reserved.contains($0.lowercased()) }) {
            throw LeoPluginFetchError.credentialHeaderConflict(name: clash)
        }
    }

    private static func remoteRequest(_ request: URLRequest) -> LeoPluginRemoteFetchRequest {
        let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
            .map { LeoCredentialHeader(name: $0.key, value: $0.value) }
        return LeoPluginRemoteFetchRequest(
            url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "GET", headers: headers, body: request.httpBody)
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
    /// Set for a credential fetch: every hop must stay on its bound host.
    private let credential: LeoPluginFetchCredential?
    private let maxBytes: Int

    private let lock = NSLock()
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<LeoPluginFetchResponse, Error>?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var hop = 0
    private var finished = false

    init(engine: LeoPluginPermissionEngine, originHost: String?, credential: LeoPluginFetchCredential?, maxBytes: Int) {
        self.engine = engine
        self.originHost = originHost
        self.credential = credential
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
        let host = LeoPluginPermissionEngine.canonicalHost(of: canonical)
        if let credential {
            // Never follow a credential off its host, and never strip it silently.
            guard host == credential.boundHost else {
                finish(.failure(LeoPluginFetchError.credentialHostMismatch(host: host ?? "?")))
                return completionHandler(nil)
            }
            for (name, value) in credential.headers { redirected.setValue(value, forHTTPHeaderField: name) }
        } else if host != originHost {
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
