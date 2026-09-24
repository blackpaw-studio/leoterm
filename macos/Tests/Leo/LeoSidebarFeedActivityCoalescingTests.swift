import Foundation
import Testing

@testable import Ghostty

/// Coverage for coalescing `agentActivity` SSE events: a chatty agent must
/// not trigger one main-actor emission per event. See `LeoActivityCoalescer`
/// for the pure buffering logic; this covers its wiring into `LeoSidebarFeed`
/// (timing, ordering against lifecycle events/list refreshes, and teardown).
///
/// Nothing here waits on the wall clock: the test fires exactly the sleep it
/// means to (the coalescing window, never a fetch deadline or an attention
/// tick), only after the feed has consumed every event sent, and proves a
/// negative with a later sentinel emission rather than by waiting a while.
/// The time limit only turns a hang into a failure.
@Suite(.timeLimit(.minutes(1)))
struct LeoSidebarFeedActivityCoalescingTests {
    /// The activity-coalescing window, and the SSE-refresh one (same length).
    static let window = UInt64(LeoSidebarFeed.activityCoalesceInterval * 1_000_000_000)

    @Test func burstOfActivityEventsWithinTheWindowProducesOneEmission() async throws {
        let harness = try await Harness.connected(results: [[agent("alpha")]])
        let baseline = await harness.recorder.values.count

        try await harness.send(
            .agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: "tool", detail: "one")),
            .agentActivity(seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: "tool", detail: "two")),
            .agentActivity(seq: 3, at: nil, agent: "alpha", activity: .idle, currentAction: .init(kind: "tool", detail: "three"))
        )

        // One flush timer for the whole window, and nothing applied yet.
        try #require(await harness.feed.activityCoalesceTask != nil, "No coalescing window opened")
        try await harness.windowOpened()
        #expect(harness.clock.pending(Self.window).count == 1)
        #expect(await harness.recorder.values.count == baseline)

        harness.clock.fire(Self.window)
        try await until { await harness.recorder.last?.rows.first?.actionDetail == "three" }

        #expect(await harness.recorder.values.count == baseline + 1)
        #expect(await harness.recorder.last?.rows.first?.activity == .idle)
        await harness.feed.stop()
    }

    @Test func laterEventForAnAgentOverwritesAnEarlierOneInTheSameWindow() async throws {
        let harness = try await Harness.connected(results: [[agent("alpha"), agent("bravo")]])
        let baseline = await harness.recorder.values.count

        try await harness.send(
            .agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "stale")),
            .agentActivity(seq: 2, at: nil, agent: "alpha", activity: .idle, currentAction: .init(kind: nil, detail: "fresh")),
            .agentActivity(seq: 3, at: nil, agent: "bravo", activity: .working, currentAction: .init(kind: nil, detail: "bravo-detail"))
        )
        try await harness.windowOpened()
        harness.clock.fire(Self.window)
        try await until { await harness.recorder.values.count > baseline }

        #expect(await harness.recorder.values.count == baseline + 1)
        let snapshot = await harness.recorder.last
        #expect(snapshot?.rows.first(where: { $0.name == "alpha" })?.actionDetail == "fresh")
        #expect(snapshot?.rows.first(where: { $0.name == "alpha" })?.activity == .idle)
        #expect(snapshot?.rows.first(where: { $0.name == "bravo" })?.activity == .working)
        await harness.feed.stop()
    }

    /// B-010: last-write-wins must not drop a working stamp that an idle
    /// event overwrote within the same window.
    @Test func workingThenIdleInOneWindowKeepsTheWorkingStamp() async throws {
        let harness = try await Harness.connected(results: [[agent("alpha")]])
        let baseline = await harness.recorder.values.count

        try await harness.send(
            .agentActivity(seq: 1, at: "2026-09-24T14:00:00Z", agent: "alpha", activity: .working, currentAction: nil),
            .agentActivity(seq: 2, at: "2026-09-24T14:00:05Z", agent: "alpha", activity: .idle, currentAction: nil)
        )
        try await harness.windowOpened()
        harness.clock.fire(Self.window)
        try await until { await harness.recorder.values.count > baseline }

        let row = await harness.recorder.last?.rows.first
        #expect(row?.activity == .idle)
        #expect(row?.lastActivityAt == LeoTimestamp.parse("2026-09-24T14:00:00Z"))
        await harness.feed.stop()
    }

    /// B-010: a state baseline that was requested before a newer working
    /// event landed must not move that agent's time backwards.
    @Test func anOlderStateBaselineNeverMovesLastActivityBackwards() async throws {
        let harness = try await Harness.connected(results: [[agent("alpha")]])
        let baseline = await harness.recorder.values.count
        try await harness.send(
            .agentActivity(seq: 1, at: "2026-09-24T14:00:10Z", agent: "alpha", activity: .working, currentAction: nil)
        )
        try await harness.windowOpened()
        harness.clock.fire(Self.window)
        try await until { await harness.recorder.values.count > baseline }

        let state = [LeoObservedAgent(name: "alpha", status: .running, activity: .idle, currentAction: nil, lastActivityAt: "2026-09-24T14:00:00Z")]
        await harness.feed.applyActivityState(state, generation: harness.feed.snapshot.generation)
        // The baseline's activity wins; its emission lands asynchronously.
        try await until { await harness.recorder.last?.rows.first?.activity == .idle }

        let row = await harness.recorder.last?.rows.first
        #expect(row?.lastActivityAt == LeoTimestamp.parse("2026-09-24T14:00:10Z"))
        await harness.feed.stop()
    }

    /// B-010: activity is pruned with the list (as display state is,
    /// B-018), so an agent recreated under a deleted one's name starts clean.
    @Test func aRecreatedAgentInheritsNoActivityFromADeletedNamesake() async throws {
        let harness = try await Harness.connected(results: [[agent("alpha")], [], [agent("alpha")]])
        let baseline = await harness.recorder.values.count
        try await harness.send(
            .agentActivity(seq: 1, at: "2026-09-24T14:00:10Z", agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "old"))
        )
        try await harness.windowOpened()
        harness.clock.fire(Self.window)
        try await until { await harness.recorder.values.count > baseline }
        #expect(await harness.recorder.last?.rows.first?.lastActivityAt != nil)

        try await harness.send(.agentStopped(seq: 2, at: nil, agent: "alpha", wakeOnMessage: false))
        try await harness.windowOpened()
        harness.clock.fire(Self.window)
        try await until { await harness.recorder.last?.rows.isEmpty == true }

        try await harness.send(.agentSpawned(seq: 3, at: nil, agent: agent("alpha")))
        try await harness.windowOpened()
        harness.clock.fire(Self.window)
        try await until { await harness.recorder.last?.rows.count == 1 }

        let row = await harness.recorder.last?.rows.first
        #expect(row?.lastActivityAt == nil)
        #expect(row?.activity == .unknown)
        #expect(row?.actionDetail == nil)
        #expect(await harness.feed.activityByName["alpha"] == nil)
        await harness.feed.stop()
    }

    @Test func equalResultingSnapshotSkipsEmission() async throws {
        let harness = try await Harness.connected(results: [[agent("alpha")]])

        // Prime the row's activity to .working/"busy" and let it flush.
        try await harness.send(.agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "busy")))
        try await harness.windowOpened()
        harness.clock.fire(Self.window)
        try await until { await harness.recorder.last?.rows.first?.actionDetail == "busy" }
        let countAfterFirstFlush = await harness.recorder.values.count

        // A second window reporting the exact same activity/detail must not
        // produce another emission. Once that flush has run, a sentinel
        // window's emission must be the very next one.
        try await harness.send(.agentActivity(seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "busy")))
        try await harness.windowOpened()
        harness.clock.fire(Self.window)
        try await until { await harness.feed.activityCoalesceTask == nil }
        try await harness.send(.agentActivity(seq: 3, at: nil, agent: "alpha", activity: .idle, currentAction: .init(kind: nil, detail: "sentinel")))
        try await harness.windowOpened()
        harness.clock.fire(Self.window)
        try await until { await harness.recorder.last?.rows.first?.actionDetail == "sentinel" }

        #expect(await harness.recorder.values.count == countAfterFirstFlush + 1)
        await harness.feed.stop()
    }

    @Test func lifecycleRefreshFlushesBufferedActivityInsteadOfLosingIt() async throws {
        let harness = try await Harness.connected(results: [[agent("alpha")], [agent("alpha"), agent("bravo")]])

        // Start a coalescing window, then -- before it flushes -- a spawn
        // event triggers a list refresh. The buffered activity must not be
        // dropped: the refresh's own emission must reflect it.
        try await harness.send(.agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "mid-window")))
        let activityFlush = try await harness.windowOpened()
        try await harness.send(.agentSpawned(seq: 2, at: nil, agent: agent("bravo")))

        // The spawn drained the window, cancelling its flush timer...
        #expect(!harness.clock.pending(Self.window).contains(activityFlush))
        // ...and scheduled its own SSE-refresh one, which fires the refresh.
        try await harness.windowOpened()
        harness.clock.fire(Self.window)
        try await until { await harness.recorder.last?.rows.count == 2 }

        #expect(await harness.daemon.listCallCount == 2)
        #expect(await harness.recorder.last?.rows.map(\.name).sorted() == ["alpha", "bravo"])
        #expect(await harness.recorder.last?.rows.first(where: { $0.name == "alpha" })?.actionDetail == "mid-window")
        await harness.feed.stop()
    }

    @Test func stopCancelsThePendingBufferAndDropsIt() async throws {
        let harness = try await Harness.connected(results: [[agent("alpha")]])
        let baseline = await harness.recorder.values.count

        try await harness.send(.agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "orphaned")))
        try await harness.windowOpened()
        await harness.feed.stop()

        #expect(harness.clock.pending(Self.window).isEmpty)
        harness.clock.fire(Self.window)
        #expect(await harness.recorder.values.count == baseline)
    }
}

private func agent(_ name: String) -> LeoAgent {
    .init(name: name, template: "default", repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
}

/// A feed wired to fakes, connected and settled: the first list refresh and
/// its activity-state fetch have both emitted, and polling is off.
private struct Harness {
    let clock = LeoFiringClock()
    let daemon: CoalescingDaemon
    let activity = CoalescingActivity()
    let recorder: CoalescingRecorder
    let feed: LeoSidebarFeed

    static func connected(results: [[LeoAgent]]) async throws -> Harness {
        let harness = await Harness(daemon: CoalescingDaemon(results: results), recorder: CoalescingRecorder())
        await harness.feed.start()
        await harness.feed.setPolling(true)
        try await until { await harness.activity.fetchCount == 1 }
        try await until {
            guard let last = await harness.recorder.last else { return false }
            return last.connectivity == .connected && !last.listRefreshSucceeded
        }
        await harness.feed.setPolling(false)
        return harness
    }

    private init(daemon: CoalescingDaemon, recorder: CoalescingRecorder) {
        self.daemon = daemon
        self.recorder = recorder
        let source = LeoSidebarActivitySource(events: { [activity] in activity.events() }, fetchState: { [activity] in activity.fetchState() })
        feed = LeoSidebarFeed(
            daemon: daemon, activity: source, sleep: { [clock] in try await clock.sleep($0) }, now: { 0 },
            sink: { [recorder] snapshot in recorder.append(snapshot) }
        )
    }

    /// Waits for a coalescing (or SSE-refresh) sleep to be pending; its id.
    @discardableResult
    func windowOpened() async throws -> Int {
        try await until { !clock.pending(LeoSidebarFeedActivityCoalescingTests.window).isEmpty }
        return clock.pending(LeoSidebarFeedActivityCoalescingTests.window)[0]
    }

    /// Sends `events` and returns once the feed has handled every one.
    func send(_ events: LeoObserveEvent...) async throws {
        events.forEach(activity.send)
        try await until { activity.hasDeliveredEverything }
    }
}

/// An event stream that knows how far its consumer has got: the feed asks
/// for the next event only after it has handled the last one.
private final class CoalescingActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [LeoObserveEvent] = []
    private var waiter: CheckedContinuation<LeoObserveEvent?, Never>?
    private var sent = 0
    private var requests = 0
    private var fetches = 0

    var fetchCount: Int { lock.withLock { fetches } }
    /// Every event sent has been handled, and the feed is waiting for more.
    var hasDeliveredEverything: Bool { lock.withLock { requests > sent && waiter != nil } }

    func events() -> AsyncStream<LeoObserveEvent> {
        AsyncStream(unfolding: { await self.next() })
    }

    func fetchState() -> [LeoObservedAgent] {
        lock.withLock { fetches += 1 }
        return []
    }

    func send(_ event: LeoObserveEvent) {
        let waiting = lock.withLock { () -> CheckedContinuation<LeoObserveEvent?, Never>? in
            sent += 1
            guard let waiter else { queue.append(event); return nil }
            self.waiter = nil
            return waiter
        }
        waiting?.resume(returning: event)
    }

    private func next() async -> LeoObserveEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> LeoObserveEvent?? in
                    requests += 1
                    if !queue.isEmpty { return .some(queue.removeFirst()) }
                    if Task.isCancelled { return .some(nil) }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let waiting = lock.withLock { () -> CheckedContinuation<LeoObserveEvent?, Never>? in
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume(returning: nil)
        }
    }
}

/// Appends on the main actor, in the order the feed emits.
@MainActor private final class CoalescingRecorder {
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
