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

    @Test func disconnectingHidesChildren() async throws {
        let harness = DispatchHarness(dispatches: [LeoDispatch(id: "d1", status: "running", callerAgent: "alpha")])
        await harness.start()
        await harness.activity.send(Self.treeHello)
        try await harness.pump { Self.ids($0) == ["d1:0"] }
        await harness.activity.send(.disconnected(reason: "gone"))
        try await harness.pump { $0.connectivity.isDisconnected }
        #expect(await harness.recorder.last?.dispatchChildren.isEmpty == true)
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
    private let dispatches: [LeoDispatch]

    init(dispatches: [LeoDispatch]) {
        self.dispatches = dispatches
        (stream, continuation) = AsyncStream.makeStream()
    }

    func events() -> AsyncStream<LeoObserveEvent> { stream }
    func send(_ event: LeoObserveEvent) { continuation.yield(event) }
    func fetchState() -> LeoObservedState {
        LeoObservedState(
            agents: [LeoObservedAgent(name: "alpha", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil)],
            dispatches: dispatches
        )
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
