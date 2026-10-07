import Foundation
import Testing

@testable import Ghostty

/// The optional `attention: {state, revision}` field, decoded from fixtures
/// shaped like the contract sent to the leo daemon (D-010). Absent means a
/// legacy daemon: nothing is invented.
struct LeoAttentionDecodingTests {
    @Test func activityEventsCarryAttentionWhenPresent() throws {
        let events = try decodedEvents()

        #expect(events[1] == .agentActivity(
            seq: 2, at: "2026-09-22T16:00:01-04:00", agent: "alpha", activity: .working, currentAction: nil,
            attention: LeoAttentionSignal(state: .working, revision: 7)
        ))
        #expect(events[2] == .agentActivity(
            seq: 3, at: "2026-09-22T16:00:02-04:00", agent: "alpha", activity: .idle, currentAction: nil,
            attention: LeoAttentionSignal(state: .needsInput, revision: 8)
        ))
    }

    @Test func helloCarriesBootIDWhenPresent() throws {
        #expect(try decodedEvents()[0] == .hello(
            seq: 1, at: "2026-09-22T16:00:00-04:00", version: "1", serverTime: "2026-09-22T16:00:00-04:00", bootID: "boot-a"
        ))
        var parser = LeoSSEParser()
        let legacy = parser.feed(Data("event: hello\ndata: {\"seq\":4}\n\n".utf8)).compactMap(LeoActivityClient.decode)
        #expect(legacy == [.hello(seq: 4, at: nil, version: nil, serverTime: nil)])
    }

    @Test func activityEventWithoutAttentionIsLegacy() throws {
        #expect(try decodedEvents()[3] == .agentActivity(
            seq: 4, at: "2026-09-22T16:00:03-04:00", agent: "legacy", activity: .working, currentAction: nil
        ))
    }

    @Test func unrecognizedStateDecodesAsUnknownInsteadOfDroppingTheEvent() throws {
        #expect(try decodedEvents()[4].attention == LeoAttentionSignal(state: .unknown, revision: 9))
    }

    @Test func spawnedAgentCarriesAttentionAtTheTopLevelOrInsideTheAgent() throws {
        let events = try decodedEvents()

        #expect(events[5].attention == LeoAttentionSignal(state: .working, revision: 1))
        #expect(events[6].attention == LeoAttentionSignal(state: .finished, revision: 2))
        #expect(events[7].attention == nil)
        guard case .agentSpawned(_, _, let agent, _) = events[7] else {
            Issue.record("expected agent_spawned")
            return
        }
        #expect(agent.name == "delta")
    }

    @Test func stateAgentsCarryAttentionWhenPresent() throws {
        struct State: Decodable { let agents: [LeoObservedAgent] }
        let agents = try LeoDaemonEnvelope<State>.decode(fixture("state_attention.json")).value().agents

        #expect(agents.map(\.attention) == [
            LeoAttentionSignal(state: .finished, revision: 12),
            LeoAttentionSignal(state: .errored, revision: 3),
            nil
        ])
    }

    @Test func legacyStateFixtureHasNoAttention() throws {
        struct State: Decodable { let agents: [LeoObservedAgent] }
        let body = Data(#"{"ok":true,"data":{"agents":[{"name":"a","activity":"working"}]}}"#.utf8)
        #expect(try LeoDaemonEnvelope<State>.decode(body).value().agents.map(\.attention) == [nil])
    }

    @Test func existingRealDaemonTranscriptDecodesAsLegacy() throws {
        var parser = LeoSSEParser()
        let events = parser.feed(try fixture("events.sse")).compactMap(LeoActivityClient.decode)
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.attention == nil })
    }

    // MARK: attention.reason (B-258)

    private func signal(_ json: String) throws -> LeoAttentionSignal {
        try JSONDecoder().decode(LeoAttentionSignal.self, from: Data(json.utf8))
    }

    @Test func activityEventDecodesPermissionReasonWithTool() throws {
        var parser = LeoSSEParser()
        let raw = "event: agent_activity\ndata: {\"seq\":9,\"agent\":\"a\",\"activity\":\"idle\",\"attention\":{\"state\":\"needs_input\",\"revision\":3,\"reason\":{\"kind\":\"permission\",\"tool\":\"Bash\",\"detail\":\"rm\"}}}\n\n"
        let event = try #require(parser.feed(Data(raw.utf8)).compactMap(LeoActivityClient.decode).first)
        #expect(event.attention?.reason == LeoAttentionReason(kind: .permission, tool: "Bash", detail: "rm"))
        #expect(event.attention?.state == .needsInput)
    }

    @Test(arguments: [#""x""#, #"{"kind":"telepathy"}"#, "{}", #"{"kind":"permission","tool":5}"#])
    func malformedOrUnknownReasonKeepsSignal(reason: String) throws {
        let decoded = try signal(#"{"state":"needs_input","revision":4,"reason":\#(reason)}"#)
        #expect(decoded == LeoAttentionSignal(state: .needsInput, revision: 4))
    }

    @Test func reasonSanitizedAndClamped() throws {
        let long = String(repeating: "a", count: 300)
        let decoded = try signal(
            #"{"state":"needs_input","revision":1,"reason":{"kind":"permission","tool":"\u001b[31mBa\nsh","detail":"\#(long)"}}"#
        )
        let reason = try #require(decoded.reason)
        #expect(reason.tool?.contains("\u{1b}") == false)
        #expect(reason.tool?.contains("\n") == false)
        #expect(try #require(reason.detail).count <= LeoAttentionReason.textLimit)
    }

    private func decodedEvents() throws -> [LeoObserveEvent] {
        var parser = LeoSSEParser()
        let events = parser.feed(try fixture("attention_events.sse")).compactMap(LeoActivityClient.decode)
        try #require(events.count == 8)
        return events
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"))
    }
}
