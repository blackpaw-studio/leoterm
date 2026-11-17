import Foundation
import Testing

@testable import LeoKit

/// B-305: Leo iOS serves client tools over a paired daemon's HTTPS API, the
/// same relay the Mac reaches over its socket.
struct LeoClientToolsHTTPTransportTests {
    private static let clientID = "ct_01JC8Z3K4M5N6P7Q8R9S0T1V2W"

    private static func helloFrame() throws -> String {
        let object = try JSONSerialization.jsonObject(with: try LeoClientToolsWireTests.fixture("hello-provider"))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "event: hello\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    @Test func providerStreamSendsBearerCFAccessAndClientToolsQuery() async throws {
        let host = "ct-\(UUID().uuidString.lowercased()).example.com"
        let frame = try Self.helloFrame()
        let recorder = HostStubURLProtocol.install(host: host) { _ in (200, Data(frame.utf8), ["Content-Type": "text/event-stream"]) }
        defer { HostStubURLProtocol.uninstall(host: host) }
        let endpoint = LeoRemoteEndpoint(
            baseURL: URL(string: "https://\(host)")!, token: "device-token",
            cfAccess: LeoCFAccessCredentials(clientID: "cf-id", clientSecret: "cf-secret")
        )
        let client = LeoClientToolsClient(transport: LeoClientToolsHTTPTransport(endpoint: endpoint, session: HostStubURLProtocol.session))

        var seen: [LeoClientToolsEvent] = []
        for await event in await client.events() { seen.append(event) }

        #expect(seen.first == .hello(clientID: Self.clientID))
        #expect(seen.count == 2)
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://\(host)/api/v1/events?client_tools=1")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "cf-id")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "cf-secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func registerClaimResultHitV1Routes() async throws {
        let web = ClientToolsWebTransport(frames: [LeoSSEEvent(name: "hello", data: String(decoding: try LeoClientToolsWireTests.fixture("hello-provider"), as: UTF8.self))])
        let client = LeoClientToolsClient(transport: LeoClientToolsHTTPTransport(web: web, logTarget: "test"))
        let stream = await client.events()
        let collector = Task { for await _ in stream {} }
        defer { collector.cancel() }
        await awaitCondition { await client.clientID != nil }
        #expect(web.streamedPaths == ["/api/v1/events?client_tools=1"])

        web.reply = { _ in (200, try LeoClientToolsWireTests.fixture("register-response")) }
        _ = try await client.register(group: "browser", tools: LeoBrowserTools.definitions)
        web.reply = { _ in (200, try LeoClientToolsWireTests.fixture("claim-response")) }
        _ = try await client.claim("ctr_1")
        web.reply = { _ in (200, try LeoClientToolsWireTests.fixture("result-response")) }
        let outcome = LeoClientToolOutcome.failure(LeoClientToolError(code: "user_has_control", message: "the user is controlling the browser"))
        try await client.postResult("ctr_1", outcome)
        web.reply = { _ in (200, try LeoClientToolsWireTests.fixture("pending-response")) }
        _ = try await client.pending()

        let sent = web.requests
        #expect(sent.map(\.method) == ["POST", "POST", "POST", "GET"])
        #expect(sent.map(\.path) == [
            "/api/v1/client-tools",
            "/api/v1/client-tools/requests/ctr_1/claim",
            "/api/v1/client-tools/requests/ctr_1/result",
            "/api/v1/client-tools/requests?pending=1",
        ])
        let register = try JSONDecoder().decode(LeoClientToolsRegisterRequest.self, from: try #require(sent[0].body))
        #expect(register.clientID == Self.clientID)
        #expect(register.group == "browser")
        let claim = try JSONDecoder().decode(LeoClientToolClaimRequest.self, from: try #require(sent[1].body))
        #expect(claim.clientID == Self.clientID)
        try LeoClientToolsWireTests.expectSameJSON(
            try JSONDecoder().decode(LeoClientToolResultRequest.self, from: try #require(sent[2].body)),
            as: try LeoClientToolsWireTests.fixture("result-request-error")
        )
    }

    @Test func aRefusedProviderStreamEndsWithItsReason() async throws {
        let web = ClientToolsWebTransport(frames: [], streamError: LeoDaemonError.daemon(code: "forbidden", message: "HTTP 403", matches: []))
        let client = LeoClientToolsClient(transport: LeoClientToolsHTTPTransport(web: web, logTarget: "test"))

        var seen: [LeoClientToolsEvent] = []
        for await event in await client.events() { seen.append(event) }

        #expect(seen.count == 1)
        guard case .disconnected = seen.first else {
            Issue.record("expected disconnected, got \(seen)")
            return
        }
        #expect(await client.clientID == nil)
    }
}

/// A web transport that streams `frames` (then stays open) and answers sends
/// from `reply`.
final class ClientToolsWebTransport: LeoWebTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let frames: [LeoSSEEvent]
    private let streamError: (any Error)?
    private var sent: [LeoHTTPRequest] = []
    private var paths: [String] = []
    private var storedReply: @Sendable (LeoHTTPRequest) throws -> (status: Int, body: Data) = { _ in (200, Data()) }

    init(frames: [LeoSSEEvent], streamError: (any Error)? = nil) {
        self.frames = frames
        self.streamError = streamError
    }

    var reply: @Sendable (LeoHTTPRequest) throws -> (status: Int, body: Data) {
        get { lock.withLock { storedReply } }
        set { lock.withLock { storedReply = newValue } }
    }

    var requests: [LeoHTTPRequest] { lock.withLock { sent } }
    var streamedPaths: [String] { lock.withLock { paths } }

    func send(_ request: LeoHTTPRequest, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        lock.withLock { sent.append(request) }
        let response = try reply(request)
        return LeoHTTPResponse(status: response.status, body: response.body)
    }

    func events(path: String) -> AsyncThrowingStream<LeoSSEEvent, any Error> {
        lock.withLock { paths.append(path) }
        let (frames, error) = (frames, streamError)
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            frames.forEach { continuation.yield($0) }
        }
    }
}

/// A URLProtocol answering by request host, so suites running in parallel
/// each own their handler.
final class HostStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: (Handler, StubURLProtocol.Recorder)] = [:]

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func install(host: String, _ handler: @escaping Handler) -> StubURLProtocol.Recorder {
        let recorder = StubURLProtocol.Recorder()
        lock.withLock { handlers[host] = (handler, recorder) }
        return recorder
    }

    static func uninstall(host: String) {
        _ = lock.withLock { handlers.removeValue(forKey: host) }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let entry = Self.lock.withLock { request.url?.host.flatMap { Self.handlers[$0] } }
        do {
            guard let (handler, recorder) = entry else { throw URLError(.cannotFindHost) }
            recorder.record(request)
            let (status, body, headers) = try handler(request)
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
