import Foundation
import Testing

@testable import Ghostty

/// Coverage for coalescing `agentActivity` SSE events: a chatty agent must
/// not trigger one main-actor emission per event. See `LeoActivityCoalescer`
/// for the pure buffering logic; this covers its wiring into `LeoSidebarFeed`
/// (timing, ordering against lifecycle events/list refreshes, and teardown).
struct LeoSidebarFeedActivityCoalescingTests {
    @Test func burstOfActivityEventsWithinTheWindowProducesOneEmission() async throws {
        let clock = CoalescingClock()
        let daemon = CoalescingDaemon(results: [[agent("alpha")]])
        let activity = CoalescingActivity()
        let recorder = CoalescingRecorder()
        let feed = makeFeed(daemon: daemon, activity: activity, recorder: recorder, sleep: { try await clock.sleep($0) })

        await feed.start(); await feed.setPolling(true)
        try await wait { await recorder.last?.connectivity == .connected }
        await feed.setPolling(false)
        let baseline = await recorder.values.count

        await activity.send(.agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: "tool", detail: "one")))
        await activity.send(.agentActivity(seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: "tool", detail: "two")))
        await activity.send(.agentActivity(seq: 3, at: nil, agent: "alpha", activity: .idle, currentAction: .init(kind: "tool", detail: "three")))
        try await wait { await clock.sleepCount > 0 }

        // Still within the coalescing window: nothing applied yet.
        #expect(await recorder.values.count == baseline)

        await pumpAdvancing(clock) { await recorder.values.count == baseline + 1 }

        #expect(await recorder.values.count == baseline + 1)
        let snapshot = await recorder.last
        #expect(snapshot?.rows.first?.activity == .idle)
        #expect(snapshot?.rows.first?.actionDetail == "three")
        await feed.stop()
    }

    @Test func laterEventForAnAgentOverwritesAnEarlierOneInTheSameWindow() async throws {
        let clock = CoalescingClock()
        let daemon = CoalescingDaemon(results: [[agent("alpha"), agent("bravo")]])
        let activity = CoalescingActivity()
        let recorder = CoalescingRecorder()
        let feed = makeFeed(daemon: daemon, activity: activity, recorder: recorder, sleep: { try await clock.sleep($0) })

        await feed.start(); await feed.setPolling(true)
        try await wait { await recorder.last?.connectivity == .connected }
        await feed.setPolling(false)

        await activity.send(.agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "stale")))
        await activity.send(.agentActivity(seq: 2, at: nil, agent: "alpha", activity: .idle, currentAction: .init(kind: nil, detail: "fresh")))
        await activity.send(.agentActivity(seq: 3, at: nil, agent: "bravo", activity: .working, currentAction: .init(kind: nil, detail: "bravo-detail")))

        await pumpAdvancing(clock) { await recorder.last?.rows.first(where: { $0.name == "alpha" })?.actionDetail == "fresh" }
        let snapshot = await recorder.last
        #expect(snapshot?.rows.first(where: { $0.name == "alpha" })?.activity == .idle)
        #expect(snapshot?.rows.first(where: { $0.name == "bravo" })?.activity == .working)
        await feed.stop()
    }

    @Test func equalResultingSnapshotSkipsEmission() async throws {
        let clock = CoalescingClock()
        let daemon = CoalescingDaemon(results: [[agent("alpha")]])
        let activity = CoalescingActivity()
        let recorder = CoalescingRecorder()
        let feed = makeFeed(daemon: daemon, activity: activity, recorder: recorder, sleep: { try await clock.sleep($0) })

        await feed.start(); await feed.setPolling(true)
        try await wait { await recorder.last?.connectivity == .connected }
        await feed.setPolling(false)

        // Prime the row's activity to .working/"busy" and let it flush.
        await activity.send(.agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "busy")))
        await pumpAdvancing(clock) { await recorder.last?.rows.first?.actionDetail == "busy" }
        let countAfterFirstFlush = await recorder.values.count

        // A second window reporting the exact same activity/detail must not
        // produce another emission.
        await activity.send(.agentActivity(seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "busy")))
        try await wait { await clock.sleepCount > 0 }
        await pumpFor(clock, duration: 0.3)

        #expect(await recorder.values.count == countAfterFirstFlush)
        await feed.stop()
    }

    @Test func lifecycleRefreshFlushesBufferedActivityInsteadOfLosingIt() async throws {
        let clock = CoalescingClock()
        let daemon = CoalescingDaemon(results: [[agent("alpha")], [agent("alpha"), agent("bravo")]])
        let activity = CoalescingActivity()
        let recorder = CoalescingRecorder()
        let feed = makeFeed(daemon: daemon, activity: activity, recorder: recorder, sleep: { try await clock.sleep($0) })

        await feed.start(); await feed.setPolling(true)
        try await wait { await recorder.last?.connectivity == .connected }
        await feed.setPolling(false)

        // Start a coalescing window, then -- before it flushes -- a spawn
        // event triggers a list refresh. The buffered activity must not be
        // dropped: the refresh's own emission (or the one right after) must
        // reflect it.
        await activity.send(.agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "mid-window")))
        try await wait { await clock.sleepCount > 0 }
        await activity.send(.agentSpawned(seq: 2, at: nil, agent: agent("bravo")))
        // The activity-coalescing sleep was cancelled by the spawn's own
        // drain; its (new) SSE-refresh-coalescing sleep needs to be
        // registered before it can be advanced, so pump the clock instead
        // of firing it exactly once.
        await pumpAdvancing(clock) { await daemon.listCallCount == 2 }
        try await wait { await recorder.last?.rows.first(where: { $0.name == "alpha" })?.actionDetail == "mid-window" }
        #expect(await recorder.last?.rows.map(\.name).sorted() == ["alpha", "bravo"])
        await feed.stop()
    }

    @Test func stopCancelsThePendingBufferAndDropsIt() async throws {
        let clock = CoalescingClock()
        let daemon = CoalescingDaemon(results: [[agent("alpha")]])
        let activity = CoalescingActivity()
        let recorder = CoalescingRecorder()
        let feed = makeFeed(daemon: daemon, activity: activity, recorder: recorder, sleep: { try await clock.sleep($0) })

        await feed.start(); await feed.setPolling(true)
        try await wait { await recorder.last?.connectivity == .connected }
        await feed.setPolling(false)
        let baseline = await recorder.values.count

        await activity.send(.agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "orphaned")))
        try await wait { await clock.sleepCount > 0 }
        await feed.stop()
        await clock.advanceAll()
        for _ in 0..<20 { await Task.yield() }

        #expect(await recorder.values.count == baseline)
    }

    private func makeFeed(daemon: CoalescingDaemon, activity: CoalescingActivity, recorder: CoalescingRecorder, sleep: @escaping @Sendable (UInt64) async throws -> Void) -> LeoSidebarFeed {
        let source = LeoSidebarActivitySource(events: { await activity.events() }, fetchState: { await activity.fetchState() })
        let sink: LeoSidebarFeed.Sink = { snapshot in Task { await recorder.append(snapshot) } }
        return LeoSidebarFeed(daemon: daemon, activity: source, sleep: sleep, sink: sink)
    }

    private func agent(_ name: String) -> LeoAgent {
        .init(name: name, template: "default", repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
    }

    private func wait(_ condition: @escaping @Sendable () async -> Bool) async throws {
        await awaitCondition(condition)
    }

    /// Repeatedly advances `clock` until `condition` holds. A single
    /// `advanceAll()` only fires whatever's registered on the clock *right
    /// now* -- a sleep scheduled moments later (e.g. the SSE-refresh sleep
    /// a lifecycle event schedules right after cancelling/draining the
    /// activity-coalescing one) wouldn't be caught by it. Pumping instead
    /// of firing once avoids depending on exact interleaving between an
    /// event's own cancellation and its follow-up scheduling.
    private func pumpAdvancing(
        _ clock: CoalescingClock, timeout: TimeInterval = 2,
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if await condition() { return }
            await clock.advanceAll()
            try? await Task.sleep(nanoseconds: 5_000_000)
        } while Date() < deadline
        Issue.record("Condition was not satisfied within \(timeout) seconds")
    }

    /// Advances `clock` repeatedly for `duration` without asserting
    /// anything -- used to prove a negative (no emission happens) while
    /// still giving any pending sleep a chance to fire.
    private func pumpFor(_ clock: CoalescingClock, duration: TimeInterval) async {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            await clock.advanceAll()
            try? await Task.sleep(nanoseconds: 5_000_000)
        } while Date() < deadline
    }
}

private actor CoalescingActivity {
    private let stream: AsyncStream<LeoObserveEvent>
    private let continuation: AsyncStream<LeoObserveEvent>.Continuation
    private(set) var fetchCount = 0
    private var state: [LeoObservedAgent] = []
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func events() -> AsyncStream<LeoObserveEvent> { stream }
    func fetchState() -> [LeoObservedAgent] { fetchCount += 1; return state }
    func send(_ event: LeoObserveEvent) { continuation.yield(event) }
}

private actor CoalescingRecorder {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    func append(_ snapshot: LeoSidebarSnapshot) { values.append(snapshot) }
}

private actor CoalescingDaemon: LeoDaemonClient {
    private var results: [[LeoAgent]]
    private var waiters: [CheckedContinuation<[LeoAgent], Never>] = []
    private(set) var listCallCount = 0

    init(results: [[LeoAgent]] = []) { self.results = results }
    func listAgents() async throws -> [LeoAgent] {
        listCallCount += 1
        if !results.isEmpty { return results.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
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

/// Unlike the other test suites' shared clocks (which cancel *every* pending
/// sleep on any one call's cancellation), this tracks each sleep by its own
/// id so that `fetchList`'s losing-race deadline sleep -- cancelled the
/// instant the list result wins -- can't spuriously cancel an unrelated
/// pending sleep (e.g. the activity-coalescing flush) that happens to be
/// outstanding on the same clock at the same time.
private actor CoalescingClock {
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextID = 0
    var sleepCount: Int { waiters.count }
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
