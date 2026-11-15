import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Agent appearance through the feed: seeded from `/state`, patched by
/// `agent_appearance_changed`, shown only while the host advertises
/// `agent_appearance` and is connected.
@Suite(.timeLimit(.minutes(1)))
struct LeoSidebarFeedAppearanceTests {
    private static let teal = LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0))
    private static let pink = LeoAgentAppearance(emoji: nil, color: .pink, emojiSource: nil, colorSource: .manual)

    private static func hello(_ features: [String] = ["agent_appearance"]) -> LeoObserveEvent {
        .hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot-a", features: features)
    }

    private func started(_ harness: TurnHarness, appearance: LeoAgentAppearance? = teal, features: [String] = ["agent_appearance"]) async throws {
        await harness.activity.setAppearance(appearance)
        await harness.start()
        await harness.activity.send(Self.hello(features))
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
    }

    @Test func seedsFromState() async throws {
        let harness = TurnHarness()
        try await started(harness)
        try await harness.pump { $0.rows.first?.appearance == Self.teal }
        await harness.stop()
    }

    @Test func eventSetsAndNullClears() async throws {
        let harness = TurnHarness()
        try await started(harness, appearance: nil)
        await harness.activity.setAppearance(Self.pink)
        await harness.activity.send(.agentAppearanceChanged(seq: 2, at: nil, agent: "alpha", appearance: Self.pink))
        try await harness.pump { $0.rows.first?.appearance == Self.pink }

        await harness.activity.setAppearance(nil)
        await harness.activity.send(.agentAppearanceChanged(seq: 3, at: nil, agent: "alpha", appearance: nil))
        try await harness.pump { $0.rows.first.map { $0.appearance == nil } ?? false }
        await harness.stop()
    }

    @Test func eventPatchesAtOnceThenRefetches() async throws {
        let harness = TurnHarness()
        try await started(harness, appearance: nil)
        let fetches = await harness.activity.fetchCount
        // /state lags on purpose: the row shows the event's value at once,
        // and a refetch follows so a /state already in flight can't leave
        // an older value up.
        await harness.activity.send(.agentAppearanceChanged(seq: 2, at: nil, agent: "alpha", appearance: Self.pink))
        try await until { await harness.recorder.values.contains { $0.rows.first?.appearance == Self.pink } }
        try await until {
            await harness.clock.advanceAll()
            return await harness.activity.fetchCount > fetches
        }
        await harness.stop()
    }

    @Test func olderDaemonShowsNothing() async throws {
        let harness = TurnHarness()
        try await started(harness, features: [])
        await harness.settle()
        let rows = await harness.recorder.values.flatMap(\.rows)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.appearance == nil })
        await harness.stop()
    }

    @Test func disconnectedRowsShowNothing() async throws {
        let harness = TurnHarness()
        try await started(harness)
        try await harness.pump { $0.rows.first?.appearance == Self.teal }
        await harness.activity.send(.disconnected(reason: "EOF"))
        try await harness.pump { $0.connectivity.isDisconnected }
        #expect(await harness.recorder.last?.rows.first.map { $0.appearance == nil } == true)
        await harness.stop()
    }

    @Test func sameValueChangesNothing() async throws {
        let harness = TurnHarness()
        try await started(harness)
        try await harness.pump { $0.rows.first?.appearance == Self.teal }
        await harness.settle()
        let before = await harness.recorder.values.count
        let shown = await harness.recorder.last
        await harness.activity.send(.agentAppearanceChanged(seq: 2, at: nil, agent: "alpha", appearance: Self.teal))
        await harness.activity.send(.agentAppearanceChanged(seq: 3, at: nil, agent: "ghost", appearance: nil))
        await harness.settle()
        #expect(await harness.recorder.values.dropFirst(before).allSatisfy { $0 == shown })
        await harness.stop()
    }

    @Test func indexReplacesWholeFromState() {
        let index = LeoAgentAppearanceIndex(byName: ["gone": Self.pink])
        #expect(index.setting("alpha", to: Self.teal)["alpha"] == Self.teal)
        #expect(index.setting("gone", to: nil)["gone"] == nil)
        let state = [
            LeoObservedAgent(name: "alpha", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil, appearance: Self.teal),
            LeoObservedAgent(name: "beta", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil),
        ]
        #expect(LeoAgentAppearanceIndex(state: state).byName == ["alpha": Self.teal])
    }
}
