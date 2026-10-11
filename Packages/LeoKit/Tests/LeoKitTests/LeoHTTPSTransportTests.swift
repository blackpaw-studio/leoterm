import Foundation
import Testing

@testable import LeoKit

/// Exercises the real URLSession path through a URLProtocol stub (the
/// system boundary); the stub's handler is global, so the suite is serial.
@Suite(.serialized)
struct LeoHTTPSTransportTests {
    @Test func sendsBearerAndCloudflareAccessHeaders() async throws {
        let recorder = StubURLProtocol.install { request in
            (200, Data(#"{"ok":true}"#.utf8), [:])
        }
        let transport = Self.transport(cfAccess: LeoCFAccessCredentials(clientID: "id.access", clientSecret: "s3cret"))
        let response = try await transport.send(LeoHTTPRequest(method: "POST", path: "/api/agent/stop", body: Data("{}".utf8)), timeout: 5)

        #expect(response.status == 200)
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://leo.example.com/api/agent/stop")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id.access")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "s3cret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func omitsOptionalHeadersWhenAbsent() async throws {
        let recorder = StubURLProtocol.install { _ in (200, Data(), [:]) }
        let transport = LeoHTTPSTransport(
            endpoint: LeoRemoteEndpoint(baseURL: URL(string: "http://10.0.0.1:8370/")!, token: nil),
            session: StubURLProtocol.session
        )
        _ = try await transport.send(LeoHTTPRequest(method: "GET", path: "/api/v1/state"), timeout: 5)

        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "http://10.0.0.1:8370/api/v1/state")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test func returnsNonSuccessResponsesForTheCallerToInterpret() async throws {
        _ = StubURLProtocol.install { _ in (401, Data(#"{"ok":false,"error":"invalid"}"#.utf8), [:]) }
        let response = try await Self.transport().send(LeoHTTPRequest(method: "GET", path: "/x"), timeout: 5)
        #expect(response.status == 401)
        #expect(String(decoding: response.body, as: UTF8.self).contains("invalid"))
    }

    @Test func mapsURLErrorsToTransportErrors() async {
        _ = StubURLProtocol.install { _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: LeoDaemonError.self) {
            _ = try await Self.transport().send(LeoHTTPRequest(method: "GET", path: "/x"), timeout: 5)
        }
    }

    @Test func streamsServerSentEvents() async throws {
        let body = "event: hello\ndata: {\"seq\":1}\n\n: ping\n\nevent: agent_stopped\ndata: {\"seq\":2,\"agent\":\"a\"}\n\n"
        let recorder = StubURLProtocol.install { _ in (200, Data(body.utf8), ["Content-Type": "text/event-stream"]) }
        var events: [LeoSSEEvent] = []
        for try await event in Self.transport().events(path: "/api/v1/events") { events.append(event) }

        #expect(events.map(\.name) == ["hello", "agent_stopped"])
        #expect(events.last?.data == #"{"seq":2,"agent":"a"}"#)
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func eventStreamFailsWithTheHTTPStatusCode() async {
        _ = StubURLProtocol.install { _ in (401, Data(#"{"ok":false,"error":"invalid bearer token"}"#.utf8), [:]) }
        await #expect(throws: LeoDaemonError.daemon(code: "unauthorized", message: "HTTP 401", matches: [])) {
            for try await _ in Self.transport().events(path: "/api/v1/events") {}
        }
    }

    @Test(arguments: ["https://evil.example.net/steal", "http://leo.example.com/api/v1/state", "https://leo.example.com:8443/api/v1/state"])
    func refusesToFollowARedirectToAnotherOrigin(target: String) async throws {
        let recorder = StubURLProtocol.install { request in
            request.url?.path == "/api/v1/state" && request.url?.host == "leo.example.com" && request.url?.port == nil && request.url?.scheme == "https"
                ? (302, Data(), ["Location": target])
                : (200, Data(#"{"ok":true}"#.utf8), [:])
        }
        let transport = Self.transport(cfAccess: LeoCFAccessCredentials(clientID: "id.access", clientSecret: "s3cret"))

        await #expect(throws: LeoDaemonError.crossOriginRedirect(target)) {
            _ = try await transport.send(LeoHTTPRequest(method: "GET", path: "/api/v1/state"), timeout: 5)
        }
        await #expect(throws: LeoDaemonError.crossOriginRedirect(target)) {
            for try await _ in transport.events(path: "/api/v1/state") {}
        }
        #expect(recorder.requests.map { $0.url?.absoluteString } == Array(repeating: "https://leo.example.com/api/v1/state", count: 2))
    }

    @Test func followsASameOriginRedirectWithItsCredentials() async throws {
        let recorder = StubURLProtocol.install { request in
            request.url?.path == "/old" ? (302, Data(), ["Location": "/api/v1/state"]) : (200, Data(#"{"ok":true}"#.utf8), [:])
        }
        let transport = Self.transport(cfAccess: LeoCFAccessCredentials(clientID: "id.access", clientSecret: "s3cret"))
        let response = try await transport.send(LeoHTTPRequest(method: "GET", path: "/old"), timeout: 5)

        #expect(response.status == 200)
        let followed = try #require(recorder.requests.last)
        #expect(followed.url?.absoluteString == "https://leo.example.com/api/v1/state")
        #expect(followed.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "s3cret")
    }

    private static func transport(cfAccess: LeoCFAccessCredentials? = nil) -> LeoHTTPSTransport {
        LeoHTTPSTransport(
            endpoint: LeoRemoteEndpoint(baseURL: URL(string: "https://leo.example.com")!, token: "tok", cfAccess: cfAccess),
            session: StubURLProtocol.session
        )
    }
}

/// A URLProtocol answering every request from one installed handler.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { stored } }
        func record(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorder = Recorder()

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func install(_ handler: @escaping Handler) -> Recorder {
        lock.withLock {
            self.handler = handler
            recorder = Recorder()
            return recorder
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (handler, recorder) = Self.lock.withLock { (Self.handler, Self.recorder) }
        recorder.record(request)
        do {
            guard let handler else { throw URLError(.unknown) }
            let (status, body, headers) = try handler(request)
            if (300..<400).contains(status), let location = headers["Location"], let target = URL(string: location, relativeTo: request.url) {
                // Follow the way URLSession does: every header but
                // Authorization rides along to the new URL.
                var redirected = request
                redirected.url = target.absoluteURL
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
