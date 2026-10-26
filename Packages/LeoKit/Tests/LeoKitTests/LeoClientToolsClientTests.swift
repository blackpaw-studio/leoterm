import Foundation
import Testing

@testable import LeoKit

struct LeoClientToolsClientTests {
    private static let clientID = "ct_01JC8Z3K4M5N6P7Q8R9S0T1V2W"

    private static func compact(_ fixture: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: try LeoClientToolsWireTests.fixture(fixture))
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func frame(_ name: String, _ fixture: String) throws -> String {
        "event: \(name)\ndata: \(try compact(fixture))\n\n"
    }

    private static func envelope(_ fixture: String) throws -> (status: Int, body: Data) {
        (200, try LeoClientToolsWireTests.fixture(fixture))
    }

    /// A client whose provider stream has said hello, so it knows its client id.
    private static func connected(
        transport: FakeClientToolsTransport = FakeClientToolsTransport(), extraFrames: String = ""
    ) async throws -> (LeoClientToolsClient, FakeClientToolsTransport, Task<[LeoClientToolsEvent], Never>) {
        transport.frames = try frame("hello", "hello-provider") + extraFrames
        let client = LeoClientToolsClient(socketPath: "/tmp/leo.sock", transport: transport)
        let stream = await client.events()
        let collector = Task { var seen: [LeoClientToolsEvent] = []; for await event in stream { seen.append(event) }; return seen }
        await awaitCondition { await client.clientID != nil }
        return (client, transport, collector)
    }

    private static func collect(_ stream: AsyncStream<LeoClientToolsEvent>) async -> [LeoClientToolsEvent] {
        var seen: [LeoClientToolsEvent] = []
        for await event in stream { seen.append(event) }
        return seen
    }

    // MARK: - Calls

    @Test func registerPostsTheGroupAndReturnsTheRevision() async throws {
        let (client, transport, collector) = try await Self.connected()
        defer { collector.cancel() }
        transport.reply = { _ in try Self.envelope("register-response") }
        let tools = [LeoClientToolDefinition(name: "browser_click", description: "Click", inputSchema: .object(["type": .string("object")]), timeoutSeconds: 30)]

        let revision = try await client.register(group: "browser", tools: tools)

        #expect(revision == 7)
        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/client-tools")
        let body = try JSONDecoder().decode(LeoClientToolsRegisterRequest.self, from: try #require(request.body))
        #expect(body == LeoClientToolsRegisterRequest(clientID: Self.clientID, group: "browser", tools: tools))
    }

    @Test func registerMapsNameConflictToATypedError() async throws {
        let (client, transport, collector) = try await Self.connected()
        defer { collector.cancel() }
        transport.reply = { _ in (409, try LeoClientToolsWireTests.fixture("register-error-name-conflict")) }
        await #expect(throws: LeoClientToolsError.nameConflict(tool: "leo_chat_post", message: "tool \"leo_chat_post\" conflicts with an existing tool")) {
            _ = try await client.register(group: "browser", tools: [])
        }
    }

    @Test func callsBeforeTheStreamSaysHelloFailWithUnknownClient() async throws {
        let transport = FakeClientToolsTransport()
        let client = LeoClientToolsClient(socketPath: "/tmp/leo.sock", transport: transport)
        await #expect(throws: LeoClientToolsError.self) { _ = try await client.register(group: "browser", tools: []) }
        await #expect(throws: LeoClientToolsError.self) { _ = try await client.claim("ctr_1") }
        #expect(transport.requests.isEmpty)
    }

    @Test func claimPostsTheClientIDAndReturnsTheRequest() async throws {
        let (client, transport, collector) = try await Self.connected()
        defer { collector.cancel() }
        transport.reply = { _ in try Self.envelope("claim-response") }

        let request = try await client.claim("ctr_01JC8Z4A5B6C7D8E9F0G1H2J3K")

        #expect(request.tool == "browser_click")
        let sent = try #require(transport.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.path == "/api/v1/client-tools/requests/ctr_01JC8Z4A5B6C7D8E9F0G1H2J3K/claim")
        #expect(try JSONDecoder().decode(LeoClientToolClaimRequest.self, from: try #require(sent.body)).clientID == Self.clientID)
    }

    @Test(arguments: [
        (409, "claim-409-owned-by-other", "owned_by_other"),
        (409, "claim-409-already-claimed", "already_claimed"),
        (404, "claim-404-unknown-request", "unknown_request"),
    ])
    func claimMapsRefusalsToTypedErrors(status: Int, fixture: String, code: String) async throws {
        let (client, transport, collector) = try await Self.connected()
        defer { collector.cancel() }
        transport.reply = { _ in (status, try LeoClientToolsWireTests.fixture(fixture)) }
        do {
            _ = try await client.claim("ctr_1")
            Issue.record("expected a refusal")
        } catch let error as LeoClientToolsError {
            #expect(error.code == code)
        }
    }

    @Test func postResultSendsTheOutcomeAndMapsConflicts() async throws {
        let (client, transport, collector) = try await Self.connected()
        defer { collector.cancel() }
        transport.reply = { _ in try Self.envelope("result-response") }
        let outcome = LeoClientToolOutcome.failure(LeoClientToolError(code: "user_has_control", message: "the user is controlling the browser"))

        try await client.postResult("ctr_1", outcome)

        let sent = try #require(transport.requests.first)
        #expect(sent.path == "/api/v1/client-tools/requests/ctr_1/result")
        try LeoClientToolsWireTests.expectSameJSON(
            try JSONDecoder().decode(LeoClientToolResultRequest.self, from: try #require(sent.body)),
            as: try LeoClientToolsWireTests.fixture("result-request-error")
        )

        transport.reply = { _ in (409, try LeoClientToolsWireTests.fixture("result-409-already-settled")) }
        await #expect(throws: LeoClientToolsError.alreadySettled(message: "request already settled")) {
            try await client.postResult("ctr_1", outcome)
        }
    }

    @Test func pendingListsUnsettledRequests() async throws {
        let (client, transport, collector) = try await Self.connected()
        defer { collector.cancel() }
        transport.reply = { _ in try Self.envelope("pending-response") }

        let pending = try await client.pending()

        #expect(pending.map(\.request.tool) == ["browser_click", "browser_snapshot", "browser_snapshot"])
        let sent = try #require(transport.requests.first)
        #expect(sent.method == "GET")
        #expect(sent.path == "/api/v1/client-tools/requests?pending=1")
    }

    @Test func aNonEnvelopeFailureBecomesATransportError() async throws {
        let (client, transport, collector) = try await Self.connected()
        defer { collector.cancel() }
        transport.reply = { _ in (502, Data("<html>bad gateway</html>".utf8)) }
        await #expect(throws: LeoDaemonError.transport("Client tools endpoint returned HTTP 502")) { _ = try await client.pending() }
    }

    // MARK: - Events

    @Test func eventsOpensTheProviderStreamAndYieldsTheClientToolFrames() async throws {
        let frames = try Self.frame("client_tools.changed", "event-client-tools-changed")
            + Self.frame("client_tool.request", "event-client-tool-request")
            + Self.frame("client_tool.cancelled", "event-client-tool-cancelled")
        let (_, transport, collector) = try await Self.connected(extraFrames: frames)
        await awaitCondition { transport.streamedPaths.count == 1 }
        // Frames are delivered in one chunk; end the stream so the collector returns.
        transport.finishStreams()
        let events = await collector.value

        #expect(transport.streamedPaths == ["/events?client_tools=1"])
        #expect(events.count == 5)
        #expect(events[0] == .hello(clientID: Self.clientID))
        #expect(events[1] == .changed(revision: 7, tools: ["browser_click", "browser_navigate", "browser_snapshot"]))
        guard case .request(let request) = events[2] else { Issue.record("expected request, got \(events[2])"); return }
        #expect(request.id == "ctr_01JC8Z4A5B6C7D8E9F0G1H2J3K")
        #expect(events[3] == .cancelled(LeoClientToolCancellation(id: "ctr_01JC8Z4A5B6C7D8E9F0G1H2J3K", agent: "alfred", reason: "timeout")))
        #expect(events[4] == .disconnected(reason: LeoSocketActivityClient.closedReason))
    }

    @Test func aRedactedRequestIsNotDeliveredButKeepsTheSequenceContiguous() async throws {
        // seq 41 hello, 42 changed, 43 redacted request, 44 cancelled: no gap.
        let frames = try Self.frame("client_tools.changed", "event-client-tools-changed")
            + Self.frame("client_tool.request", "event-client-tool-request-redacted")
            + Self.frame("client_tool.cancelled", "event-client-tool-cancelled")
        let (_, transport, collector) = try await Self.connected(extraFrames: frames)
        transport.finishStreams()
        let events = await collector.value
        #expect(!events.contains { if case .request = $0 { true } else { false } })
        #expect(!events.contains { if case .gap = $0 { true } else { false } })
        #expect(events.contains { if case .cancelled = $0 { true } else { false } })
    }

    @Test func aSequenceGapYieldsGapSoTheSessionCanRecoverPending() async throws {
        // hello is seq 41; the changed fixture is seq 42; the cancelled fixture jumps to 44 after a dropped 43.
        let frames = try Self.frame("client_tools.changed", "event-client-tools-changed")
            + Self.frame("client_tool.cancelled", "event-client-tool-cancelled")
        let (_, transport, collector) = try await Self.connected(extraFrames: frames)
        transport.finishStreams()
        let events = await collector.value
        let gapIndex = try #require(events.firstIndex(of: .gap(expected: 43, received: 44)))
        let cancelledIndex = try #require(events.firstIndex { if case .cancelled = $0 { true } else { false } })
        #expect(gapIndex < cancelledIndex)
    }

    @Test func unrelatedEventsCountTowardTheSequence() async throws {
        let frames = try Self.frame("client_tools.changed", "event-client-tools-changed")
            + "event: agent_state_changed\ndata: {\"seq\":43,\"agent\":\"a\"}\n\n"
            + Self.frame("client_tool.cancelled", "event-client-tool-cancelled")
        let (_, transport, collector) = try await Self.connected(extraFrames: frames)
        transport.finishStreams()
        let events = await collector.value
        #expect(!events.contains { if case .gap = $0 { true } else { false } })
    }

    @Test func aHelloWithoutAClientIDEndsTheStreamAsUnsupported() async throws {
        let transport = FakeClientToolsTransport()
        transport.frames = "event: hello\ndata: {\"seq\":1,\"features\":[]}\n\n"
        let client = LeoClientToolsClient(socketPath: "/tmp/leo.sock", transport: transport)
        let events = await Self.collect(await client.events())
        #expect(events == [.disconnected(reason: LeoClientToolsClient.unsupportedReason)])
        #expect(await client.clientID == nil)
    }

    @Test func streamEndClearsTheClientIDSoCallsFailInsteadOfUsingAStaleOne() async throws {
        let (client, transport, collector) = try await Self.connected()
        transport.finishStreams()
        _ = await collector.value
        #expect(await client.clientID == nil)
        await #expect(throws: LeoClientToolsError.self) { _ = try await client.pending() }
    }

    @Test func aTransportFailureEndsWithItsReason() async throws {
        let transport = FakeClientToolsTransport()
        transport.streamError = LeoDaemonError.socketMissing(path: "/tmp/leo.sock")
        let client = LeoClientToolsClient(socketPath: "/tmp/leo.sock", transport: transport)
        let events = await Self.collect(await client.events())
        #expect(events == [.disconnected(reason: String(describing: LeoDaemonError.socketMissing(path: "/tmp/leo.sock")))])
    }
}

private final class FakeClientToolsTransport: LeoSocketActivityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [LeoHTTPRequest] = []
    private var streamPaths: [String] = []
    private var continuations: [AsyncThrowingStream<Data, Error>.Continuation] = []

    var frames = ""
    var streamError: (any Error)?
    var reply: @Sendable (LeoHTTPRequest) throws -> (status: Int, body: Data) = { _ in (200, Data()) }

    var requests: [LeoHTTPRequest] { lock.withLock { sent } }
    var streamedPaths: [String] { lock.withLock { streamPaths } }

    func finishStreams() {
        let open = lock.withLock { continuations }
        open.forEach { $0.finish() }
    }

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        lock.withLock { sent.append(request) }
        let response = try reply(request)
        return LeoHTTPResponse(status: response.status, body: response.body)
    }

    func stream(path: String, socketPath _: String, idleTimeout _: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { streamPaths.append(path) }
        let frames = frames
        let error = streamError
        return AsyncThrowingStream { continuation in
            if let error { continuation.finish(throwing: error); return }
            if !frames.isEmpty { continuation.yield(Data(frames.utf8)) }
            lock.withLock { continuations.append(continuation) }
        }
    }
}
