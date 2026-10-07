import Foundation
import Testing

@testable import Ghostty

/// B-261 through the feed: a compaction shows on its row from `started`
/// until the end event (or any reset), and the end asks for a fresh
/// `/state`, which is what carries the new context percentage.
@Suite(.timeLimit(.minutes(1)))
struct LeoSidebarFeedCompactionTests {
    private static func usage(_ percent: Double) -> LeoAgentUsage {
        LeoAgentUsage(
            sessionID: "s1", session: LeoUsageTotals(tokens: 1000, costUSD: 0.1),
            context: LeoContextUsage(tokens: Int64(percent) * 2000, window: 200_000, percent: percent)
        )
    }

    private static let hello = LeoObserveEvent.hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot-a", features: ["agent_usage"])

    private static func compaction(
        _ phase: LeoCompactionPhase, agent: String = "alpha", trigger: LeoCompactionTrigger? = .auto, seq: Int = 2
    ) -> LeoObserveEvent {
        .agentCompaction(seq: seq, compaction: LeoCompactionEvent(agent: agent, phase: phase, trigger: trigger, contextPercent: 91))
    }

    private func started(_ harness: TurnHarness) async throws {
        await harness.start()
        await harness.activity.send(Self.hello)
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
    }

    @Test func compactionStartShowsOnRow() async throws {
        let harness = TurnHarness()
        try await started(harness)
        await harness.activity.send(Self.compaction(.started))
        try await harness.pump { $0.rows.first?.compaction == LeoRowCompaction(trigger: .auto) }
        await harness.stop()
    }

    @Test func compactionEndClearsAndRefreshesState() async throws {
        let harness = TurnHarness(usage: Self.usage(91))
        try await started(harness)
        try await harness.pump { $0.rows.first?.metadata?.usage?.context?.percent == 91 }
        await harness.activity.send(Self.compaction(.started))
        try await harness.pump { $0.rows.first?.compaction != nil }
        await harness.settle()
        let fetches = await harness.activity.fetchCount

        await harness.activity.setUsage(Self.usage(12))
        await harness.activity.send(Self.compaction(.completed, seq: 3))
        try await harness.pump { $0.rows.first?.compaction == nil && $0.rows.first?.metadata?.usage?.context?.percent == 12 }
        #expect(await harness.activity.fetchCount > fetches)
        await harness.stop()
    }

    @Test func failedCompactionClearsToo() async throws {
        let harness = TurnHarness()
        try await started(harness)
        await harness.activity.send(Self.compaction(.started))
        try await harness.pump { $0.rows.first?.compaction != nil }
        await harness.activity.send(Self.compaction(.failed, seq: 3))
        try await harness.pump { $0.rows.first?.compaction == nil }
        await harness.stop()
    }

    @Test func compactionForUnknownAgentDropped() async throws {
        let harness = TurnHarness()
        try await started(harness)
        await harness.activity.send(Self.compaction(.started, agent: "ghost"))
        await harness.settle()
        #expect(await harness.recorder.values.allSatisfy { $0.rows.allSatisfy { $0.compaction == nil } })
        #expect(await harness.feed.compactions == .empty)
        await harness.stop()
    }

    @Test func disconnectClearsCompaction() async throws {
        let harness = TurnHarness()
        try await started(harness)
        await harness.activity.send(Self.compaction(.started))
        try await harness.pump { $0.rows.first?.compaction != nil }
        await harness.activity.send(.disconnected(reason: "gone"))
        try await harness.pump { $0.connectivity.isDisconnected && $0.rows.first?.compaction == nil }
        #expect(await harness.feed.compactions == .empty)
        await harness.stop()
    }

    @Test func gapClearsCompaction() async throws {
        let harness = TurnHarness()
        try await started(harness)
        await harness.activity.send(Self.compaction(.started))
        try await harness.pump { $0.rows.first?.compaction != nil }
        await harness.activity.send(.gap(expected: 3, received: 9))
        try await harness.pump { $0.rows.first?.compaction == nil }
        await harness.stop()
    }

    @Test func stoppedOrRespawnedAgentClearsCompaction() async throws {
        let harness = TurnHarness()
        try await started(harness)
        await harness.activity.send(Self.compaction(.started))
        try await harness.pump { $0.rows.first?.compaction != nil }
        await harness.activity.send(.agentStopped(seq: 3, at: nil, agent: "alpha", wakeOnMessage: nil))
        try await harness.pump { $0.rows.first?.compaction == nil }

        await harness.activity.send(Self.compaction(.started, seq: 4))
        try await harness.pump { $0.rows.first?.compaction != nil }
        let agent = LeoAgent(name: "alpha", template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: "t1", restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
        await harness.activity.send(.agentSpawned(seq: 5, at: nil, agent: agent))
        try await harness.pump { $0.rows.first?.compaction == nil }
        await harness.stop()
    }

    @Test func bootChangeClearsCompaction() async throws {
        let harness = TurnHarness()
        try await started(harness)
        await harness.activity.send(Self.compaction(.started))
        try await harness.pump { $0.rows.first?.compaction != nil }
        await harness.activity.send(.hello(seq: 9, at: nil, version: "1", serverTime: nil, bootID: "boot-b", features: []))
        try await harness.pump { $0.rows.first?.compaction == nil }
        await harness.stop()
    }

    @Test func turnCompletedClearsCompaction() async throws {
        let harness = TurnHarness()
        try await started(harness)
        await harness.activity.send(Self.compaction(.started))
        try await harness.pump { $0.rows.first?.compaction != nil }
        await harness.activity.send(.agentTurnCompleted(seq: 3, turn: LeoTurnCompletion(agent: "alpha", outcome: .completed, preview: "x")))
        try await harness.pump { $0.rows.first?.compaction == nil }
        await harness.stop()
    }

    @Test func compactionDoesNotFlushActivityCoalescer() async throws {
        let harness = TurnHarness()
        try await started(harness)
        await harness.settle()
        try await Task.sleep(nanoseconds: 50_000_000)
        await harness.activity.send(.agentActivity(seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: nil))
        await harness.activity.send(Self.compaction(.started, seq: 3))
        try await Task.sleep(nanoseconds: 50_000_000)
        let feed = harness.feed
        #expect(await feed.activityCoalesceTask != nil)
        #expect(await !feed.activityCoalescer.isEmpty)
        await harness.stop()
    }
}
