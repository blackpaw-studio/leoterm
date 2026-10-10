import Foundation
import Testing

@testable import Ghostty

/// B-283 through the feed: the effective environment names come from
/// `/state`, `agent_spawned` and a set-environment `agent_state_changed`.
/// A lifecycle state change omits the fields, and absent means unchanged.
@Suite(.timeLimit(.minutes(1)))
struct LeoSidebarFeedEnvironmentsTests {
    private static let override = LeoAgentEnvironments(names: ["aws", "prod"], source: .override, error: nil)

    private static func hello(_ features: [String] = ["agent_environments"]) -> LeoObserveEvent {
        .hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot-a", features: features)
    }

    private func started(_ harness: TurnHarness, features: [String] = ["agent_environments"]) async throws {
        await harness.activity.setEnvironments(Self.override)
        await harness.start()
        await harness.activity.send(Self.hello(features))
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
    }

    @Test func absentFieldsKeepEnvironments() async throws {
        let harness = TurnHarness()
        try await started(harness)
        try await harness.pump { $0.rows.first?.environments == Self.override }
        await harness.activity.send(.agentStateChanged(seq: 2, at: nil, agent: "alpha", status: .starting, restarts: 1, wakeOnMessage: nil))
        await harness.activity.send(.agentStateChanged(seq: 3, at: nil, agent: "alpha", status: .running, restarts: 1, wakeOnMessage: nil))
        await harness.settle()
        #expect(await harness.recorder.last?.rows.first?.environments == Self.override)
        await harness.stop()
    }

    @Test func setEventReplacesAndResolvesError() async throws {
        let harness = TurnHarness()
        await harness.activity.setEnvironments(LeoAgentEnvironments(names: ["gone"], source: .override, error: "environment gone is not configured"))
        await harness.start()
        await harness.activity.send(Self.hello())
        try await harness.pump { $0.rows.first?.environments?.error != nil }
        // The /state that follows the event agrees with it.
        await harness.activity.setEnvironments(LeoAgentEnvironments(names: [], source: .default, error: nil))
        let patch = LeoAgentEnvironmentsPatch(names: .set([]), source: .set(.default), error: .cleared)
        await harness.activity.send(.agentStateChanged(seq: 2, at: nil, agent: "alpha", status: nil, restarts: nil, wakeOnMessage: nil, environments: patch))
        try await harness.pump { $0.rows.first?.environments == LeoAgentEnvironments(names: [], source: .default, error: nil) }
        await harness.stop()
    }

    @Test func olderDaemonShowsNothing() async throws {
        let harness = TurnHarness()
        try await started(harness, features: [])
        await harness.settle()
        let rows = await harness.recorder.values.flatMap(\.rows)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.environments == nil })
        await harness.stop()
    }
}
