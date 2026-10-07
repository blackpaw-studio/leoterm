import Foundation
import Testing

@testable import Ghostty

/// B-259 through the feed: a turn's preview and the snapshot's usage show
/// on the row only when the daemon advertised `bridge_turns` / `agent_usage`,
/// attach to their own incarnation, and clear when the connection does.
@Suite(.timeLimit(.minutes(1)))
struct LeoSidebarFeedTurnTests {
    private static let usage = LeoAgentUsage(
        sessionID: "s1", session: LeoUsageTotals(tokens: 12_345, costUSD: 0.42),
        context: LeoContextUsage(tokens: 74_000, window: 200_000, percent: 37)
    )

    private static func hello(_ features: [String], boot: String = "boot-a") -> LeoObserveEvent {
        .hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: boot, features: features)
    }

    private static func turn(_ preview: String = "Fixed the bug", agent: String = "alpha", outcome: LeoTurnOutcome = .completed, seq: Int = 2) -> LeoObserveEvent {
        .agentTurnCompleted(seq: seq, turn: LeoTurnCompletion(agent: agent, outcome: outcome, preview: preview))
    }

    @Test func turnPreviewShowsAfterHelloWithBridgeTurns() async throws {
        let harness = TurnHarness()
        await harness.start()
        await harness.activity.send(Self.hello(["bridge_turns"]))
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
        await harness.activity.send(Self.turn(outcome: .aborted))
        try await harness.pump { $0.rows.first?.lastTurn == LeoTurnPreview(text: "Fixed the bug", outcome: .aborted) }
        await harness.stop()
    }

    @Test func turnIgnoredWithoutBridgeTurnsFeature() async throws {
        let harness = TurnHarness()
        await harness.start()
        await harness.activity.send(Self.hello(["dispatch_tree"]))
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
        await harness.activity.send(Self.turn())
        await harness.settle()
        #expect(await harness.recorder.values.allSatisfy { $0.rows.allSatisfy { $0.lastTurn == nil } })
        await harness.stop()
    }

    @Test func usageHiddenWithoutAgentUsageFeature() async throws {
        let harness = TurnHarness(usage: Self.usage)
        await harness.start()
        await harness.activity.send(Self.hello(["bridge_turns"]))
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
        await harness.activity.send(Self.turn())
        await harness.settle()
        #expect(await harness.recorder.values.allSatisfy { $0.rows.allSatisfy { $0.metadata?.usage == nil } })

        await harness.activity.send(Self.hello(["bridge_turns", "agent_usage"]))
        try await harness.pump { $0.rows.first?.metadata?.usage == Self.usage }
        await harness.stop()
    }

    @Test func turnEventRequestsMetadataRefresh() async throws {
        let harness = TurnHarness()
        await harness.start()
        await harness.activity.send(Self.hello(["bridge_turns", "agent_usage"]))
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
        await harness.settle()
        let fetches = await harness.activity.fetchCount

        await harness.activity.send(Self.turn())
        try await until {
            await harness.clock.advanceAll()
            return await harness.activity.fetchCount > fetches
        }
        let afterTurn = await harness.activity.fetchCount
        await harness.activity.send(.agentUsage(seq: 3, agent: "alpha", usage: Self.usage))
        try await until {
            await harness.clock.advanceAll()
            return await harness.activity.fetchCount > afterTurn
        }
        await harness.stop()
    }

    @Test func previewClearedOnRespawnDisconnectHostSwitch() async throws {
        let harness = TurnHarness()
        await harness.start()
        await harness.activity.send(Self.hello(["bridge_turns"]))
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
        await harness.activity.send(Self.turn())
        try await harness.pump { $0.rows.first?.lastTurn != nil }

        // A stop event forgets it.
        await harness.activity.send(.agentStopped(seq: 3, at: nil, agent: "alpha", wakeOnMessage: nil))
        try await harness.pump { $0.rows.first?.lastTurn == nil }

        // A boot change drops what an older boot recorded.
        await harness.activity.send(Self.turn("again", seq: 4))
        try await harness.pump { $0.rows.first?.lastTurn?.text == "again" }
        await harness.activity.send(Self.hello(["bridge_turns"], boot: "boot-b"))
        try await harness.pump { $0.rows.first?.lastTurn == nil }

        // Disconnect hides it, and a retry doesn't bring it back.
        await harness.activity.send(Self.turn("third", seq: 5))
        try await harness.pump { $0.rows.first?.lastTurn?.text == "third" }
        await harness.activity.send(.disconnected(reason: "gone"))
        try await harness.pump { $0.connectivity.isDisconnected && $0.rows.first?.lastTurn == nil }
        #expect(await harness.feed.turnPreviews == .empty)
        #expect(await harness.feed.daemonFeatures == .none)

        // A host switch carries nothing over.
        let other = TurnActivity(usage: nil)
        await harness.feed.updateConnection(
            host: .remote("work"), generation: 1,
            phase: .connected(daemon: TurnDaemon(), activitySource: .init(events: { await other.events() }, observedState: { await other.fetchState() }))
        )
        try await harness.pump { $0.rows.first?.host == .remote("work") }
        await harness.settle()
        #expect(await harness.recorder.values.filter { $0.rows.first?.host == .remote("work") }.allSatisfy { $0.rows.first?.lastTurn == nil })
        await harness.stop()
    }

    @Test func turnForUnknownAgentDropped() async throws {
        let harness = TurnHarness()
        await harness.start()
        await harness.activity.send(Self.hello(["bridge_turns"]))
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
        await harness.activity.send(Self.turn(agent: "ghost"))
        await harness.settle()
        #expect(await harness.feed.turnPreviews.preview(name: "ghost", startedAt: "t1") == nil)
        #expect(await harness.recorder.values.allSatisfy { $0.rows.allSatisfy { $0.lastTurn == nil } })
        await harness.stop()
    }

    @Test func aTurnNeverFlushesThePendingActivityWindow() async throws {
        let harness = TurnHarness()
        await harness.start()
        await harness.activity.send(Self.hello(["bridge_turns"]))
        try await harness.pump { $0.rows.first?.startedAt == "t1" }
        await harness.settle()
        try await Task.sleep(nanoseconds: 50_000_000)
        await harness.activity.send(.agentActivity(seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: nil))
        await harness.activity.send(Self.turn(seq: 3))
        try await Task.sleep(nanoseconds: 50_000_000)
        let feed = harness.feed
        #expect(await feed.activityCoalesceTask != nil, "the window's flush is still armed")
        #expect(await !feed.activityCoalescer.isEmpty, "the activity is still buffered, not drained")
        await harness.stop()
    }
}

private struct TurnHarness {
    let clock = TurnClock()
    let activity: TurnActivity
    let recorder = TurnRecorder()
    let feed: LeoSidebarFeed

    init(usage: LeoAgentUsage? = nil) {
        let activity = TurnActivity(usage: usage)
        self.activity = activity
        let clock = clock
        let recorder = recorder
        feed = LeoSidebarFeed(
            daemon: TurnDaemon(),
            activity: .init(events: { await activity.events() }, observedState: { await activity.fetchState() }),
            sleep: { try await clock.sleep($0) },
            now: { 0 },
            sink: { snapshot in Task { await recorder.append(snapshot) } }
        )
    }

    func start() async {
        await feed.start()
        await feed.setPolling(true)
    }

    func stop() async { await feed.stop() }

    func pump(_ condition: @escaping @Sendable (LeoSidebarSnapshot) -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until(sourceLocation: sourceLocation) {
            if let last = await recorder.last, condition(last) { return true }
            await clock.advanceAll()
            return false
        }
    }

    func settle() async {
        for _ in 0..<8 {
            await clock.advanceAll()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor TurnActivity {
    private let stream: AsyncStream<LeoObserveEvent>
    private let continuation: AsyncStream<LeoObserveEvent>.Continuation
    private let usage: LeoAgentUsage?
    private(set) var fetchCount = 0

    init(usage: LeoAgentUsage?) {
        self.usage = usage
        (stream, continuation) = AsyncStream.makeStream()
    }

    func events() -> AsyncStream<LeoObserveEvent> { stream }
    func send(_ event: LeoObserveEvent) { continuation.yield(event) }

    func fetchState() -> LeoObservedState {
        fetchCount += 1
        return LeoObservedState(agents: [
            LeoObservedAgent(name: "alpha", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil, startedAt: "t1", usage: usage)
        ])
    }
}

private actor TurnDaemon: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] {
        [LeoAgent(name: "alpha", template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: "t1", restarts: nil, stoppedReason: nil, wakeOnMessage: nil)]
    }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { fatalError() }
    func start(_ name: String) async throws { fatalError() }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { fatalError() }
    func restart(_ name: String) async throws -> LeoAgent { fatalError() }
    func reset(_ name: String) async throws { fatalError() }
    func setTemplate(_ name: String, template: String) async throws { fatalError() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { fatalError() }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { fatalError() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { fatalError() }
    func logs(_ name: String, lines: Int?) async throws -> String { fatalError() }
}

private actor TurnRecorder {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    func append(_ value: LeoSidebarSnapshot) { values.append(value) }
}

private actor TurnClock {
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextID = 0
    func sleep(_ nanoseconds: UInt64) async throws {
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func advanceAll() {
        let pending = waiters
        waiters = [:]
        pending.values.forEach { $0.resume() }
    }
    private func cancel(_ id: Int) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }
}
