import Foundation
import Testing

@testable import Ghostty

/// B-257 through the feed: `/state` dispatches and live `dispatch_changed`
/// records nest under their caller's row, only when the daemon advertised
/// `dispatch_tree` and the connection is live.
@Suite(.timeLimit(.minutes(1)))
struct LeoSidebarFeedDispatchTests {
    private static let treeHello = LeoObserveEvent.hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot-a", features: ["dispatch_tree"])

    @Test func baselineAndLiveDispatchesNestUnderTheCallersRow() async throws {
        let harness = DispatchHarness(dispatches: [LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")])
        await harness.start()
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.activity.send(Self.treeHello)
        try await harness.pump { Self.ids($0) == ["d1:0"] }

        await harness.activity.send(.dispatchChanged(seq: 2, dispatch: LeoDispatch(id: "d2", status: "running", callerAgent: "x", parentDispatchID: "d1")))
        try await harness.pump { Self.ids($0) == ["d1:0", "d2:1"] }

        await harness.activity.send(.dispatchChanged(seq: 3, dispatch: LeoDispatch(id: "d2", status: "done", callerAgent: "x", parentDispatchID: "d1")))
        try await harness.pump { Self.ids($0) == ["d1:0"] }
        await harness.stop()
    }

    @Test func withoutTheFeatureNothingShows() async throws {
        let harness = DispatchHarness(dispatches: [LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")])
        await harness.start()
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.activity.send(.hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot-a"))
        await harness.activity.send(.dispatchChanged(seq: 2, dispatch: LeoDispatch(id: "d2", status: "running", callerAgent: "alpha")))
        await harness.settle()
        #expect(await harness.recorder.values.allSatisfy { $0.dispatchChildren.isEmpty })
        await harness.stop()
    }

    /// The 1 s dispatch ticker republishes records whose tokens moved; a
    /// record that looks the same must not emit.
    @Test func anUnchangedRecordDoesNotEmit() async throws {
        let harness = DispatchHarness(dispatches: [LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")])
        await harness.start()
        await harness.activity.send(Self.treeHello)
        try await harness.pump { Self.ids($0) == ["d1:0"] }
        await harness.settle()
        // No clock advance from here: a poll tick would emit on its own.
        try await Task.sleep(nanoseconds: 50_000_000)
        let emitted = await harness.recorder.values.count
        await harness.activity.send(.dispatchChanged(seq: 2, dispatch: LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")))
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(await harness.recorder.values.count == emitted)

        await harness.activity.send(.dispatchChanged(seq: 3, dispatch: LeoDispatch(id: "d1", status: "idle", callerAgent: "alpha")))
        try await until { await harness.recorder.last?.dispatchChildren["alpha"]?.first?.dispatch.status == "idle" }
        #expect(await harness.recorder.values.count == emitted + 1, "a visible change emits once")
        await harness.stop()
    }

    /// A drop must not blank the nested rows: the last-known ones stay
    /// until a reconnect's baseline reconciles them.
    @Test func disconnectingKeepsTheLastKnownChildren() async throws {
        let harness = DispatchHarness(dispatches: [LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")])
        await harness.start()
        await harness.activity.send(Self.treeHello)
        try await harness.pump { Self.ids($0) == ["d1:0"] }
        await harness.activity.send(.disconnected(reason: "gone"))
        try await harness.pump { $0.connectivity.isDisconnected }
        #expect(Self.ids(await harness.recorder.last!) == ["d1:0"])
        await harness.stop()
    }

    @Test func aHostSwitchForgetsTheOldHostsDispatches() async throws {
        let harness = DispatchHarness(dispatches: [LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")])
        await harness.start()
        await harness.activity.send(Self.treeHello)
        try await harness.pump { Self.ids($0) == ["d1:0"] }

        let activityB = DispatchActivity(dispatches: [])
        await harness.feed.updateConnection(
            host: .remote("work"), generation: 1,
            phase: .connected(daemon: DispatchDaemon(), activitySource: .init(events: { await activityB.events() }, observedState: { await activityB.fetchState() }))
        )
        try await harness.pump { $0.rows.first?.host == .remote("work") }
        await harness.settle()
        let remote = await harness.recorder.values.filter { $0.rows.first?.host == .remote("work") }
        #expect(remote.allSatisfy { $0.dispatchChildren.isEmpty })
        await harness.stop()
    }

    /// Dispatch and seq-only events must leave a pending activity window,
    /// attention candidates and recovery alone: the window flushes at its
    /// own time, the candidate commits as usual, and nothing refetches.
    @Test func dispatchAndSeqOnlyEventsLeaveThePendingActivityWindowAlone() async throws {
        let harness = DispatchHarness(dispatches: [LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")])
        await harness.start()
        await harness.activity.send(Self.treeHello)
        try await harness.pump { Self.ids($0) == ["d1:0"] }
        await harness.settle()
        try await Task.sleep(nanoseconds: 50_000_000)
        let fetches = await harness.activity.fetchCount

        await harness.activity.send(.agentActivity(
            seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: nil, attention: .init(state: .needsInput, revision: 5)
        ))
        await harness.activity.send(.other(seq: 3, type: "agent_turn_completed"))
        await harness.activity.send(.dispatchChanged(seq: 4, dispatch: LeoDispatch(id: "d2", status: "running", callerAgent: "alpha")))
        try await until { Self.ids(await harness.recorder.last!) == ["d1:0", "d2:0"] }
        try await Task.sleep(nanoseconds: 50_000_000)
        let feed = harness.feed
        #expect(await feed.activityCoalesceTask != nil, "the window's flush is still armed")
        #expect(await !feed.activityCoalescer.isEmpty, "the activity is still buffered, not drained")
        #expect(await feed.attention.nextDeadline != nil, "the attention candidate is still pending")
        #expect(await !feed.recovering)
        let early = await harness.recorder.last?.rows.first
        #expect(early?.activity == .idle, "the dispatch emission must not flush the activity window early")
        #expect(early?.attention == nil, "nor commit the attention candidate before its window")

        try await harness.pump { $0.rows.first?.activity == .working }
        try await harness.pump { $0.rows.first?.attention == .needsInput }
        #expect(await harness.activity.fetchCount <= fetches + 1, "no recovery refetch (at most the flush's own metadata snapshot)")
        await harness.stop()
    }

    /// An activity baseline older than an applied one must not touch the
    /// dispatches (it could drop a child or bring back an ended one).
    @Test func anOlderActivityBaselineLeavesDispatchesAlone() async throws {
        let harness = DispatchHarness(dispatches: [])
        await harness.start()
        await harness.activity.send(Self.treeHello)
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.settle()
        let feed = harness.feed
        let older = await feed.nextMetadataRequest()
        let newer = await feed.nextMetadataRequest()
        let generation = await feed.snapshot.generation
        let agents = await harness.activity.fetchState().agents
        await feed.applyActivityState(
            LeoObservedState(agents: agents, dispatches: [LeoDispatch(id: "d2", status: "running", callerAgent: "alpha")]),
            generation: generation, metadataRequest: newer, dispatchMark: await feed.dispatchTree.mark
        )
        await feed.applyActivityState(
            LeoObservedState(agents: agents, dispatches: [LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")]),
            generation: generation, metadataRequest: older, dispatchMark: await feed.dispatchTree.mark
        )
        try await harness.pump { Self.ids($0) == ["d2:0"] }
        #expect(await feed.dispatchTree.children(of: "alpha").map(\.id) == ["d2"])
        await harness.stop()
    }

    /// A metadata snapshot that lands after a newer baseline is rejected
    /// whole: its dispatches too.
    @Test func aMetadataSnapshotLandingAfterANewerBaselineLeavesDispatchesAlone() async throws {
        let harness = DispatchHarness(dispatches: [LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")])
        await harness.start()
        await harness.activity.send(Self.treeHello)
        try await harness.pump { Self.ids($0) == ["d1:0"] }
        await harness.settle()

        // A metadata fetch starts and is held with a stale answer.
        await harness.activity.setDispatches([
            LeoDispatch(id: "d1", status: "running", callerAgent: "alpha"), LeoDispatch(id: "stale", status: "running", callerAgent: "alpha")
        ])
        await harness.activity.holdNext()
        await harness.activity.send(.agentActivity(seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: nil))
        try await until {
            await harness.clock.advanceAll()
            return await harness.activity.heldCount == 1
        }

        // A newer baseline applies meanwhile.
        let feed = harness.feed
        let agents = await harness.activity.fetchState().agents
        await feed.applyActivityState(
            LeoObservedState(agents: agents, dispatches: [LeoDispatch(id: "d1", status: "running", callerAgent: "alpha"), LeoDispatch(id: "d3", status: "running", callerAgent: "alpha")]),
            generation: await feed.snapshot.generation, metadataRequest: await feed.nextMetadataRequest(), dispatchMark: await feed.dispatchTree.mark
        )
        try await harness.pump { Self.ids($0) == ["d1:0", "d3:0"] }

        await harness.activity.releaseHeld()
        await harness.settle()
        #expect(await feed.dispatchTree.children(of: "alpha").map(\.id) == ["d1", "d3"])
        #expect(Self.ids(await harness.recorder.last!) == ["d1:0", "d3:0"])
        await harness.stop()
    }

    /// The mark is read when the baseline fetch starts: a child that
    /// arrives live while `/state` is in flight survives it.
    @Test func aChildUpsertedWhileTheBaselineIsInFlightSurvivesIt() async throws {
        let harness = DispatchHarness(dispatches: [])
        await harness.start()
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.settle()
        await harness.activity.holdNext()
        await harness.activity.send(Self.treeHello)
        try await until {
            await harness.clock.advanceAll()
            return await harness.activity.heldCount == 1
        }
        await harness.activity.send(.dispatchChanged(seq: 2, dispatch: LeoDispatch(id: "d2", status: "running", callerAgent: "alpha")))
        try await harness.pump { Self.ids($0) == ["d2:0"] }
        await harness.activity.releaseHeld()
        await harness.settle()
        #expect(Self.ids(await harness.recorder.last!) == ["d2:0"])
        await harness.stop()
    }

    /// A restarted daemon (new boot id) drops the old records and the ids
    /// that ended under it.
    @Test func aNewBootClearsRecordsAndEndedIDs() async throws {
        let harness = DispatchHarness(dispatches: [])
        await harness.start()
        await harness.activity.send(Self.treeHello)
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.activity.send(.dispatchChanged(seq: 2, dispatch: LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")))
        await harness.activity.send(.dispatchChanged(seq: 3, dispatch: LeoDispatch(id: "d1", status: "done", callerAgent: "alpha")))
        await harness.activity.send(.dispatchChanged(seq: 4, dispatch: LeoDispatch(id: "d2", status: "running", callerAgent: "alpha")))
        try await harness.pump { Self.ids($0) == ["d2:0"] }

        await harness.activity.setDispatches([LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")])
        await harness.activity.send(.hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot-b", features: ["dispatch_tree"]))
        try await harness.pump { Self.ids($0) == ["d1:0"] }
        await harness.stop()
    }

    private static let seqHello = LeoObserveEvent.hello(
        seq: 1, at: nil, version: "1", serverTime: nil, bootID: "boot-a", features: ["dispatch_tree", "state_seq"]
    )

    /// `state_seq`: a hello re-fetches `/state` even on a connect, closing
    /// the create-between-GET-and-subscribe gap.
    @Test func aHelloAdvertisingStateSeqRefetchesState() async throws {
        let harness = DispatchHarness(dispatches: [])
        await harness.start()
        await harness.activity.send(.connected)
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.settle()
        let before = await harness.activity.fetchCount
        await harness.activity.send(Self.seqHello)
        try await until {
            await harness.clock.advanceAll()
            return await harness.activity.fetchCount > before
        }
        await harness.stop()
    }

    @Test func aHelloWithoutStateSeqDoesNotRefetchOnConnect() async throws {
        let harness = DispatchHarness(dispatches: [])
        await harness.start()
        await harness.activity.send(.connected)
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.settle()
        let before = await harness.activity.fetchCount
        await harness.activity.send(Self.treeHello)
        await harness.settle()
        #expect(await harness.activity.fetchCount == before)
        await harness.stop()
    }

    @Test func aBaselineOlderThanALiveEventKeepsTheRecord() async throws {
        let harness = DispatchHarness(dispatches: [])
        await harness.start()
        await harness.activity.send(Self.seqHello)
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.activity.send(.dispatchChanged(seq: 10, dispatch: LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")))
        try await harness.pump { Self.ids($0) == ["d1:0"] }
        await harness.settle()

        let feed = harness.feed
        let agents = await harness.activity.fetchState().agents
        await feed.applyActivityState(
            LeoObservedState(agents: agents, dispatches: [], seq: 5),
            generation: await feed.snapshot.generation, metadataRequest: await feed.nextMetadataRequest(), dispatchMark: await feed.dispatchTree.mark
        )
        #expect(await feed.dispatchTree.children(of: "alpha").map(\.id) == ["d1"])
        await harness.stop()
    }

    private static func ids(_ snapshot: LeoSidebarSnapshot) -> [String] {
        (snapshot.dispatchChildren["alpha"] ?? []).map { "\($0.id):\($0.depth)" }
    }
}

private struct DispatchHarness {
    let clock = DispatchClock()
    let activity: DispatchActivity
    let recorder = DispatchRecorder()
    let feed: LeoSidebarFeed

    init(dispatches: [LeoDispatch]) {
        let activity = DispatchActivity(dispatches: dispatches)
        self.activity = activity
        let clock = clock
        let recorder = recorder
        feed = LeoSidebarFeed(
            daemon: DispatchDaemon(),
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

private actor DispatchActivity {
    private let stream: AsyncStream<LeoObserveEvent>
    private let continuation: AsyncStream<LeoObserveEvent>.Continuation
    private var dispatches: [LeoDispatch]
    private(set) var fetchCount = 0
    private var holdsNext = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var heldCount: Int { held.count }

    init(dispatches: [LeoDispatch]) {
        self.dispatches = dispatches
        (stream, continuation) = AsyncStream.makeStream()
    }

    func events() -> AsyncStream<LeoObserveEvent> { stream }
    func send(_ event: LeoObserveEvent) { continuation.yield(event) }
    func setDispatches(_ dispatches: [LeoDispatch]) { self.dispatches = dispatches }
    /// The next `/state` answers with what's set now but waits for `releaseHeld`.
    func holdNext() { holdsNext = true }
    func releaseHeld() {
        let pending = held
        held = []
        pending.forEach { $0.resume() }
    }

    func fetchState() async -> LeoObservedState {
        fetchCount += 1
        let answer = LeoObservedState(
            agents: [LeoObservedAgent(name: "alpha", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil)],
            dispatches: dispatches
        )
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { held.append($0) }
        }
        return answer
    }
}

private actor DispatchDaemon: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] {
        [LeoAgent(name: "alpha", template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)]
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

private actor DispatchRecorder {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    func append(_ value: LeoSidebarSnapshot) { values.append(value) }
}

private actor DispatchClock {
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
