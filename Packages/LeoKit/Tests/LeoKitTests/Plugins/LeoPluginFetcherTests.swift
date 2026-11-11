import Foundation
import Testing

@testable import LeoKit

/// Serves canned responses keyed by absolute URL, so parallel tests never share state
/// as long as each uses its own host.
private final class PluginFetchStubProtocol: URLProtocol, @unchecked Sendable {
    enum Route: Sendable {
        case respond(status: Int, headers: [String: String], chunks: [Data])
        case redirect(status: Int, to: String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]

    static func serve(_ url: String, _ route: Route) { lock.withLock { routes[url] = route } }
    static func seen(_ url: String) -> [URLRequest] { lock.withLock { requests[url] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url?.absoluteString else { return }
        let route: Route? = Self.lock.withLock {
            Self.requests[url, default: []].append(request)
            return Self.routes[url]
        }
        switch route {
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
        case .redirect(let status, let target)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Location": target])!
            var next = URLRequest(url: URL(string: target)!)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        case .respond(let status, let headers, let chunks)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

private func makeFetcher(
    network: [String] = ["*.example.com", "api.example.com"], limiter: LeoPluginRateLimiter = LeoPluginRateLimiter()
) -> LeoPluginFetcher {
    LeoPluginFetcher(
        pluginID: "studio.blackpaw.demo",
        engine: LeoPluginPermissionEngine(permissions: LeoPluginPermissions(network: network)),
        limiter: limiter,
        configure: { $0.protocolClasses = [PluginFetchStubProtocol.self] })
}

private func text(_ s: String) -> PluginFetchStubProtocol.Route {
    .respond(status: 200, headers: ["Content-Type": "text/plain", "ETag": "\"v1\""], chunks: [Data(s.utf8)])
}

struct LeoPluginFetcherTests {
    @Test func fetchesAnAllowedHostAndPassesStatusHeadersAndBody() async throws {
        PluginFetchStubProtocol.serve("https://ok1.example.com/x", text("hello"))
        let response = try await makeFetcher().fetch(url: "https://ok1.example.com/x", init: LeoPluginFetchInit())
        #expect(response.status == 200)
        #expect(response.body == "hello")
        #expect(response.headers["etag"] == "\"v1\"")
    }

    @Test func aHostOutsideTheAllowlistIsDeniedBeforeAnyRequest() async throws {
        PluginFetchStubProtocol.serve("https://evil.test/x", text("nope"))
        await #expect(throws: LeoPluginFetchError.self) {
            try await makeFetcher().fetch(url: "https://evil.test/x", init: LeoPluginFetchInit())
        }
        #expect(PluginFetchStubProtocol.seen("https://evil.test/x").isEmpty)
    }

    @Test func plainHttpIsDenied() async throws {
        await #expect(throws: LeoPluginFetchError.self) {
            try await makeFetcher().fetch(url: "http://ok2.example.com/x", init: LeoPluginFetchInit())
        }
    }

    @Test func aRedirectToAnAllowedHostIsFollowed() async throws {
        PluginFetchStubProtocol.serve("https://r1.example.com/a", .redirect(status: 302, to: "https://r2.example.com/b"))
        PluginFetchStubProtocol.serve("https://r2.example.com/b", text("landed"))
        let response = try await makeFetcher().fetch(url: "https://r1.example.com/a", init: LeoPluginFetchInit())
        #expect(response.body == "landed")
    }

    @Test func aRedirectHopOutsideTheAllowlistIsRejectedAndNeverRequested() async throws {
        PluginFetchStubProtocol.serve("https://r3.example.com/a", .redirect(status: 302, to: "https://evil.net/steal"))
        PluginFetchStubProtocol.serve("https://evil.net/steal", text("leaked"))
        do {
            _ = try await makeFetcher().fetch(url: "https://r3.example.com/a", init: LeoPluginFetchInit())
            Issue.record("expected the redirect to be denied")
        } catch let LeoPluginFetchError.denied(reason) {
            #expect(reason.contains("redirect hop 1"))
        }
        #expect(PluginFetchStubProtocol.seen("https://evil.net/steal").isEmpty)
    }

    @Test func aRedirectDowngradeToHttpIsRejected() async throws {
        PluginFetchStubProtocol.serve("https://r4.example.com/a", .redirect(status: 301, to: "http://r4.example.com/b"))
        await #expect(throws: LeoPluginFetchError.self) {
            try await makeFetcher().fetch(url: "https://r4.example.com/a", init: LeoPluginFetchInit())
        }
    }

    @Test func aRedirectLoopStopsAtTheHopLimit() async throws {
        PluginFetchStubProtocol.serve("https://loop.example.com/a", .redirect(status: 302, to: "https://loop.example.com/a"))
        await #expect(throws: LeoPluginFetchError.self) {
            try await makeFetcher().fetch(url: "https://loop.example.com/a", init: LeoPluginFetchInit())
        }
    }

    @Test func authorizationIsNotForwardedToAnotherHostOnRedirect() async throws {
        PluginFetchStubProtocol.serve("https://a1.example.com/a", .redirect(status: 302, to: "https://a2.example.com/b"))
        PluginFetchStubProtocol.serve("https://a2.example.com/b", text("ok"))
        _ = try await makeFetcher().fetch(
            url: "https://a1.example.com/a",
            init: LeoPluginFetchInit(headers: ["Authorization": "Bearer secret", "X-Keep": "1"]))
        let hop = try #require(PluginFetchStubProtocol.seen("https://a2.example.com/b").first)
        #expect(hop.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(hop.value(forHTTPHeaderField: "X-Keep") == "1")
    }

    @Test func aBodyOverFiveMegabytesIsRejected() async throws {
        let limit = LeoPluginFetcher.maxBodyBytes
        let chunk = Data(repeating: 0x61, count: 1024 * 1024)
        let chunks = Array(repeating: chunk, count: limit / chunk.count) + [Data([0x61])]
        PluginFetchStubProtocol.serve("https://big.example.com/x", .respond(status: 200, headers: [:], chunks: chunks))
        await #expect(throws: LeoPluginFetchError.bodyTooLarge(limit: limit)) {
            try await makeFetcher().fetch(url: "https://big.example.com/x", init: LeoPluginFetchInit())
        }
    }

    @Test func aBodyOfExactlyFiveMegabytesIsAccepted() async throws {
        let limit = LeoPluginFetcher.maxBodyBytes
        PluginFetchStubProtocol.serve(
            "https://edge.example.com/x", .respond(status: 200, headers: [:], chunks: [Data(repeating: 0x62, count: limit)]))
        let response = try await makeFetcher().fetch(url: "https://edge.example.com/x", init: LeoPluginFetchInit())
        #expect(response.body.utf8.count == limit)
    }

    @Test func aDeclaredContentLengthOverTheCapIsRejectedUpFront() async throws {
        let limit = LeoPluginFetcher.maxBodyBytes
        PluginFetchStubProtocol.serve(
            "https://decl.example.com/x",
            .respond(status: 200, headers: ["Content-Length": String(limit + 1)], chunks: [Data("x".utf8)]))
        await #expect(throws: LeoPluginFetchError.bodyTooLarge(limit: limit)) {
            try await makeFetcher().fetch(url: "https://decl.example.com/x", init: LeoPluginFetchInit())
        }
    }

    @Test func a304PassesThroughWithItsHeadersAndTheConditionalHeaderIsSent() async throws {
        PluginFetchStubProtocol.serve("https://etag.example.com/x", .respond(status: 304, headers: ["ETag": "\"v1\""], chunks: []))
        let response = try await makeFetcher().fetch(
            url: "https://etag.example.com/x", init: LeoPluginFetchInit(headers: ["If-None-Match": "\"v1\""]))
        #expect(response.status == 304)
        #expect(response.body == "")
        #expect(response.headers["etag"] == "\"v1\"")
        let request = try #require(PluginFetchStubProtocol.seen("https://etag.example.com/x").first)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    }

    @Test func serverErrorsAreResponsesNotRejections() async throws {
        PluginFetchStubProtocol.serve("https://err.example.com/x", .respond(status: 500, headers: [:], chunks: [Data("boom".utf8)]))
        let response = try await makeFetcher().fetch(url: "https://err.example.com/x", init: LeoPluginFetchInit())
        #expect(response.status == 500)
        #expect(response.body == "boom")
    }

    @Test func postsABodyWithItsMethod() async throws {
        PluginFetchStubProtocol.serve("https://post.example.com/x", text("ok"))
        _ = try await makeFetcher().fetch(
            url: "https://post.example.com/x",
            init: LeoPluginFetchInit(method: "post", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: "a=1"))
        let request = try #require(PluginFetchStubProtocol.seen("https://post.example.com/x").first)
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        })
        #expect(String(decoding: body, as: UTF8.self) == "a=1")
    }

    @Test(arguments: [
        LeoPluginFetchInit(method: "TRACE"),
        LeoPluginFetchInit(headers: ["Cookie": "a=b"]),
        LeoPluginFetchInit(headers: ["Host": "evil.com"]),
        LeoPluginFetchInit(headers: ["X-A": "b\r\nX-Injected: 1"]),
        LeoPluginFetchInit(method: "GET", body: "x"),
    ])
    func refusesMalformedOrDangerousRequestOptions(init options: LeoPluginFetchInit) async throws {
        PluginFetchStubProtocol.serve("https://bad.example.com/x", text("ok"))
        await #expect(throws: LeoPluginFetchError.self) {
            try await makeFetcher().fetch(url: "https://bad.example.com/x", init: options)
        }
        #expect(PluginFetchStubProtocol.seen("https://bad.example.com/x").isEmpty)
    }

    @Test func theSixtyFirstRequestInAMinuteIsRateLimitedAndDeniedOnesDontCount() async throws {
        PluginFetchStubProtocol.serve("https://rate.example.com/x", text("ok"))
        let limiter = LeoPluginRateLimiter(maxPerWindow: 2, now: { 100 })
        let fetcher = makeFetcher(limiter: limiter)
        // A denied request must not burn quota.
        _ = try? await fetcher.fetch(url: "https://evil.test/x", init: LeoPluginFetchInit())
        _ = try await fetcher.fetch(url: "https://rate.example.com/x", init: LeoPluginFetchInit())
        _ = try await fetcher.fetch(url: "https://rate.example.com/x", init: LeoPluginFetchInit())
        do {
            _ = try await fetcher.fetch(url: "https://rate.example.com/x", init: LeoPluginFetchInit())
            Issue.record("expected a rate-limit rejection")
        } catch let LeoPluginFetchError.rateLimited(retryAfter) {
            #expect(retryAfter == 60)
        }
        #expect(PluginFetchStubProtocol.seen("https://rate.example.com/x").count == 2)
    }

    @Test func theInFlightSlotIsReleasedAfterAFailure() async throws {
        PluginFetchStubProtocol.serve("https://slot.example.com/x", .respond(status: 200, headers: [:], chunks: [Data(repeating: 1, count: LeoPluginFetcher.maxBodyBytes + 1)]))
        let limiter = LeoPluginRateLimiter(maxPerWindow: 100, maxInFlight: 1, now: { 0 })
        let fetcher = makeFetcher(limiter: limiter)
        for _ in 0..<3 {
            await #expect(throws: LeoPluginFetchError.bodyTooLarge(limit: LeoPluginFetcher.maxBodyBytes)) {
                try await fetcher.fetch(url: "https://slot.example.com/x", init: LeoPluginFetchInit())
            }
        }
    }

    @Test func transportFailuresBecomeReadableRejections() async throws {
        // No route registered: the stub fails the load.
        do {
            _ = try await makeFetcher().fetch(url: "https://down.example.com/x", init: LeoPluginFetchInit())
            Issue.record("expected a failure")
        } catch let LeoPluginFetchError.network(reason) {
            #expect(!reason.isEmpty)
        }
    }

    @Test func theSessionSendsNoCookiesAndKeepsNoCache() {
        let configuration = LeoPluginFetcher.sessionConfiguration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }
}
