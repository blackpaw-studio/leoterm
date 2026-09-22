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
