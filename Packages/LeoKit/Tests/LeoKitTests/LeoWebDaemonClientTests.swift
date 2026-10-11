import Foundation
import Testing

@testable import LeoKit

struct LeoWebDaemonClientTests {
    @Test func pairsWithTheCodeAndDeviceName() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":{"device_id":"dev-1","token":"t0k"}}"#])
        let grant = try await LeoWebDaemonClient.pair(code: "abc", deviceName: "Evan's iPhone", transport: transport)

        #expect(grant == LeoPairingGrant(deviceID: "dev-1", token: "t0k"))
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/pair")
        let json = try Self.object(request)
        #expect(json["pairing_code"] as? String == "abc")
        #expect(json["device_name"] as? String == "Evan's iPhone")
    }

    @Test(arguments: [
        (401, #"{"ok":false,"error":"invalid or expired pairing code"}"#, "unauthorized", "invalid or expired pairing code"),
        (429, #"{"ok":false,"error":"too many pairing attempts; try again later"}"#, "rate_limited", "too many pairing attempts; try again later"),
        (503, "", "unavailable", "HTTP 503"),
    ])
    func pairingFailuresCarryTheDaemonsReason(status: Int, body: String, code: String, message: String) async {
        let transport = FakeWebTransport(responses: [status: body])
        await #expect(throws: LeoDaemonError.daemon(code: code, message: message, matches: [])) {
            _ = try await LeoWebDaemonClient.pair(code: "abc", deviceName: "d", transport: transport)
        }
    }

    @Test func fetchesTheStateSnapshot() async throws {
        let transport = FakeWebTransport(responses: [
            200: #"{"ok":true,"data":{"agents":[{"name":"a","status":"running","activity":"idle","harness":"claude","template":"coding"}],"meta":{"seq":7}}}"#,
        ])
        let state = try await LeoWebDaemonClient(transport: transport).fetchState()

        #expect(state.seq == 7)
        #expect(state.agents.map(\.name) == ["a"])
        #expect(state.agents.first?.harness == "claude")
        #expect(state.agents.first?.template == "coding")
        #expect(await transport.requests.map(\.path) == ["/api/v1/state"])
    }

    @Test func constructsEveryControlRoute() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":[{"name":"work"},{"name":"aws"}]}"#])
        let client = LeoWebDaemonClient(transport: transport)
        try await client.stop("a/b")
        try await client.start("a")
        try await client.restart("a")
        try await client.interrupt("a b")
        let names = try await client.environmentNames()
        try await client.setEnvironments("a", names: ["work"])

        #expect(names == ["aws", "work"])
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["POST", "POST", "POST", "POST", "POST", "GET", "POST"])
        #expect(requests.map(\.path) == [
            "/api/agent/stop", "/api/agent/start", "/api/agent/stop", "/api/agent/start",
            "/api/v1/agents/a%20b/interrupt", "/api/v1/environments", "/api/v1/agents/a/environments",
        ])
        #expect(try Self.object(requests[0])["name"] as? String == "a/b")
        #expect(try Self.object(requests[0])["wake_on_message"] as? Bool == false)
        #expect(try Self.object(requests[1])["name"] as? String == "a")
        #expect(try Self.object(requests[6])["environments"] as? [String] == ["work"])
    }

    @Test func controlFailuresUseTheDaemonsMessage() async {
        let transport = FakeWebTransport(responses: [404: #"{"ok":false,"error":"no such agent \"a\""}"#])
        await #expect(throws: LeoDaemonError.daemon(code: "not_found", message: #"no such agent "a""#, matches: [])) {
            try await LeoWebDaemonClient(transport: transport).interrupt("a")
        }
    }

    @Test func restartStopsBeforeStartingAndSkipsStartWhenStopFails() async {
        let transport = FakeWebTransport(responses: [500: #"{"ok":false,"error":"stop failed"}"#])
        await #expect(throws: LeoDaemonError.self) { try await LeoWebDaemonClient(transport: transport).restart("a") }
        #expect(await transport.requests.map(\.path) == ["/api/agent/stop"])
    }

    @Test func decodesTheEventStream() async throws {
        let transport = FakeWebTransport(responses: [:], events: [
            LeoSSEEvent(name: "hello", data: #"{"seq":3,"version":"0.36.0"}"#, id: nil),
            LeoSSEEvent(name: "agent_stopped", data: #"{"seq":4,"agent":"a","wake_on_message":false}"#, id: nil),
            LeoSSEEvent(name: "nonsense", data: "not json", id: nil),
        ])
        var events: [LeoObserveEvent] = []
        for try await event in LeoWebDaemonClient(transport: transport).events() { events.append(event) }

        #expect(events.map(\.sequence) == [3, 4])
        #expect(events.last == .agentStopped(seq: 4, at: nil, agent: "a", wakeOnMessage: false))
        #expect(await transport.streamedPaths == ["/api/v1/events"])
    }

    private static func object(_ request: LeoHTTPRequest) throws -> [String: Any] {
        let body = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

/// Answers every request with the one configured status (the first key).
actor FakeWebTransport: LeoWebTransport {
    private let status: Int
    private let body: String
    private let streamed: [LeoSSEEvent]
    private(set) var requests: [LeoHTTPRequest] = []
    private(set) var streamedPaths: [String] = []

    init(responses: [Int: String], events: [LeoSSEEvent] = []) {
        status = responses.keys.first ?? 200
        body = responses.values.first ?? #"{"ok":true}"#
        streamed = events
    }

    func send(_ request: LeoHTTPRequest, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        requests.append(request)
        return LeoHTTPResponse(status: status, body: Data(body.utf8))
    }

    nonisolated func events(path: String) -> AsyncThrowingStream<LeoSSEEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let events = await self.recordStream(path)
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private func recordStream(_ path: String) -> [LeoSSEEvent] {
        streamedPaths.append(path)
        return streamed
    }
}
