import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Agent briefs through the feed: seeded from `/state`, patched by
/// `agent_brief`, cleared when the machine turns briefs off, refetched when it
/// turns them on, and shown only while the host advertises `agent_brief`.
@Suite(.timeLimit(.minutes(1)))
struct LeoSidebarFeedBriefTests {
    private static let first = LeoAgentBrief(goal: "Ship it", status: "Waiting on review")
    private static let second = LeoAgentBrief(goal: "Ship it", status: "Merging")

    private static func hello(_ features: [String] = ["agent_brief"]) -> LeoObserveEvent {
        .hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot-a", features: features)
    }

    private func started(_ harness: TurnHarness, brief: LeoAgentBrief? = first, features: [String] = ["agent_brief"]) async throws {
        await harness.activity.setBrief(brief)
        await harness.start()
        await harness.activity.send(Self.hello(features))
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
    }

    @Test func seedsFromState() async throws {
        let harness = TurnHarness()
        try await started(harness)
        try await harness.pump { $0.rows.first?.brief == Self.first }
        await harness.stop()
    }

    @Test func eventSetsAndNullClears() async throws {
        let harness = TurnHarness()
        try await started(harness, brief: nil)
        await harness.activity.setBrief(Self.second)
        await harness.activity.send(.agentBrief(seq: 2, at: nil, agent: "alpha", brief: Self.second))
        try await harness.pump { $0.rows.first?.brief == Self.second }

        await harness.activity.setBrief(nil)
        await harness.activity.send(.agentBrief(seq: 3, at: nil, agent: "alpha", brief: nil))
        try await harness.pump { $0.rows.first.map { $0.brief == nil } ?? false }
        await harness.stop()
    }

    @Test func configOffClearsEveryBrief() async throws {
        let harness = TurnHarness()
        try await started(harness)
        try await harness.pump { $0.rows.first?.brief == Self.first }
        await harness.activity.setBrief(nil)
        await harness.activity.send(.briefConfigChanged(seq: 2, enabled: false))
        try await harness.pump { $0.rows.first.map { $0.brief == nil } ?? false }
        await harness.stop()
    }

    @Test func configOnRefetchesState() async throws {
        let harness = TurnHarness()
        try await started(harness, brief: nil)
        let fetches = await harness.activity.fetchCount
        await harness.activity.setBrief(Self.first)
        await harness.activity.send(.briefConfigChanged(seq: 2, enabled: true))
        try await harness.pump { $0.rows.first?.brief == Self.first }
        #expect(await harness.activity.fetchCount > fetches)
        await harness.stop()
    }

    @Test func hiddenWithoutTheFeature() async throws {
        let harness = TurnHarness()
        try await started(harness, features: [])
        await harness.settle()
        #expect(await harness.recorder.values.allSatisfy { $0.rows.allSatisfy { $0.brief == nil } })
        await harness.stop()
    }
}
