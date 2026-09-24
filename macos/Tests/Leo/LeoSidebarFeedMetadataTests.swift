import Foundation
import Testing

@testable import Ghostty

/// Row metadata comes only from whole `/state` snapshots, and an entry
/// paints a row only when its `started_at` matches that row's (D-074).
/// Each fake answers with the daemon's data as of the call and can hold
/// the answer back, so every interleaving here is deterministic.
@Suite(.timeLimit(.minutes(1)))
struct LeoSidebarFeedMetadataTests {
    @Test func aSnapshotPaintsTheMatchingRow() async throws {
        let harness = MetadataHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", task: "Reading")])
        await harness.start()
        try await harness.pump { $0.rows.first?.metadata?.task == "Reading" }
        let alpha = try #require(await harness.recorder.last?.rows.first)
        #expect(alpha.metadata?.lastActiveAt != nil)
        await harness.stop()
    }

    @Test func aStaleSnapshotNeverPaintsARecreatedNamesake() async throws {
        let harness = MetadataHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", task: "old")])
        await harness.start()
        try await harness.pump { $0.rows.first?.metadata?.task == "old" }
        await harness.settle()

        // A metadata fetch answered by the old incarnation is held back.
        await harness.activity.holdNext()
        await harness.activity.send(.agentActivity(seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: nil))
        try await harness.pumpAsync { _ in await harness.activity.heldCount == 1 }

        // alpha is deleted and recreated; the list sees the new one.
        await harness.daemon.setAgents([("alpha", "s2")])
        await harness.activity.setState([observed("alpha", "s2", task: "new")])
        await harness.activity.send(.agentStopped(seq: 3, at: nil, agent: "alpha", wakeOnMessage: nil))
        await harness.activity.send(.agentSpawned(seq: 4, at: nil, agent: agent("alpha", "s2")))
        try await harness.pump { $0.rows.first?.startedAt == "s2" }
        #expect(await harness.recorder.last?.rows.first?.metadata == nil, "the old incarnation's metadata is gone with it")

        await harness.activity.releaseHeld()
        try await harness.pump { $0.rows.first?.metadata?.task == "new" }
        let painted = await harness.recorder.values.flatMap(\.rows).filter { $0.startedAt == "s2" }.compactMap(\.metadata?.task)
        #expect(!painted.contains("old"))
        await harness.stop()
    }

    @Test func aSnapshotStartedBeforeASpawnLeavesTheNewRowBare() async throws {
        let harness = MetadataHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", task: "alpha task")])
        await harness.start()
        try await harness.pump { $0.rows.first?.metadata != nil }
        await harness.settle()

        // The held answer predates beta, whose deleted namesake it still lists.
        await harness.activity.setState([observed("alpha", "s1", task: "alpha task"), observed("beta", "s0", task: "ghost")])
        await harness.activity.holdNext()
        await harness.activity.send(.agentActivity(seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: nil))
        try await harness.pumpAsync { _ in await harness.activity.heldCount == 1 }

        await harness.daemon.setAgents([("alpha", "s1"), ("beta", "s5")])
        await harness.activity.setState([observed("alpha", "s1", task: "alpha task"), observed("beta", "s5", task: "beta task")])
        await harness.activity.send(.agentSpawned(seq: 3, at: nil, agent: agent("beta", "s5")))
        try await harness.pump { $0.rows.map(\.name) == ["alpha", "beta"] }

        await harness.activity.releaseHeld()
        try await harness.pump { $0.rows.last?.metadata?.task == "beta task" }
        let betaTasks = await harness.recorder.values.flatMap(\.rows).filter { $0.name == "beta" }.compactMap(\.metadata?.task)
        #expect(!betaTasks.contains("ghost"))
        #expect(await harness.recorder.last?.rows.first?.metadata?.task == "alpha task")
        await harness.stop()
    }

    @Test func aHostSwitchMidFetchDropsTheOldHostsSnapshot() async throws {
        let harness = MetadataHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", task: "host A")])
        await harness.start()
        try await harness.pump { $0.rows.first?.metadata?.task == "host A" }
        await harness.settle()

        await harness.activity.holdNext()
        await harness.activity.send(.agentActivity(seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: nil))
        try await harness.pumpAsync { _ in await harness.activity.heldCount == 1 }

        // Host B has a namesake with the very same started_at.
        let daemonB = MetadataDaemon(agents: [("alpha", "s1")])
        let activityB = MetadataActivity(state: [observed("alpha", "s1", task: "host B")])
        await harness.feed.updateConnection(
            host: .remote("work"), generation: 1,
            phase: .connected(daemon: daemonB, activitySource: .init(events: { await activityB.events() }, fetchState: { await activityB.fetchState() }))
        )
        try await harness.pump { $0.rows.first?.host == .remote("work") && $0.rows.first?.metadata?.task == "host B" }

        await harness.activity.releaseHeld()
        await harness.settle()
        let remoteTasks = await harness.recorder.values.flatMap(\.rows).filter { $0.host == .remote("work") }.compactMap(\.metadata?.task)
        #expect(!remoteTasks.contains("host A"))
        #expect(await harness.recorder.last?.rows.first?.metadata?.task == "host B")
        await harness.stop()
    }

    /// A fetch that already finished but hasn't hopped back onto the feed
    /// when the host switches: cancellation can't stop it, the guard must.
    @Test func aFinishedFetchLandingAfterAHostSwitchIsDropped() async throws {
        let harness = MetadataHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", task: "host A")])
        await harness.start()
        try await harness.pump { $0.rows.first?.metadata != nil }
        let request = await harness.feed.nextMetadataRequest()
        let generation = await harness.feed.snapshot.generation

        let daemonB = MetadataDaemon(agents: [("alpha", "s1")])
        let activityB = MetadataActivity(state: [])
        await harness.feed.updateConnection(
            host: .remote("work"), generation: 1,
            phase: .connected(daemon: daemonB, activitySource: .init(events: { await activityB.events() }, fetchState: { await activityB.fetchState() }))
        )
        try await harness.pump { $0.rows.first?.host == .remote("work") }
        let applied = await harness.feed.applyMetadata([observed("alpha", "s1", task: "host A")], request: request, generation: generation)
        #expect(!applied)
        let stillCurrent = await harness.feed.applyMetadata(
            [observed("alpha", "s1", task: "host A")], request: request, generation: await harness.feed.snapshot.generation
        )
        #expect(!stillCurrent, "a request from before the switch is retired even under the new generation")
        await harness.stop()
    }

    @Test func anOlderSnapshotLandingAfterANewerOneIsDropped() async throws {
        let harness = MetadataHarness(agents: [("alpha", "s1")], state: [])
        await harness.start()
        try await harness.pump { $0.rows.first?.name == "alpha" }
        await harness.settle()
        let older = await harness.feed.nextMetadataRequest()
        let newer = await harness.feed.nextMetadataRequest()
        let generation = await harness.feed.snapshot.generation
        #expect(await harness.feed.applyMetadata([observed("alpha", "s1", task: "newer")], request: newer, generation: generation))
        #expect(!(await harness.feed.applyMetadata([observed("alpha", "s1", task: "older")], request: older, generation: generation)))
        await harness.stop()
    }

    @Test func aHostSwitchClearsMetadataImmediately() async throws {
        let harness = MetadataHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", task: "host A")])
        await harness.start()
        try await harness.pump { $0.rows.first?.metadata != nil }

        let daemonB = MetadataDaemon(agents: [("alpha", "s1")])
        let activityB = MetadataActivity(state: [])
        await activityB.holdNext()
        await harness.feed.updateConnection(
            host: .remote("work"), generation: 1,
            phase: .connected(daemon: daemonB, activitySource: .init(events: { await activityB.events() }, fetchState: { await activityB.fetchState() }))
        )
        try await harness.pump { $0.rows.first?.host == .remote("work") }
        #expect(await harness.recorder.last?.rows.first?.metadata == nil)
        await activityB.releaseHeld()
        await harness.stop()
    }

    @Test func disconnectingClearsMetadata() async throws {
        let harness = MetadataHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", task: "Reading")])
        await harness.start()
        try await harness.pump { $0.rows.first?.metadata != nil }
        await harness.activity.send(.disconnected(reason: "gone"))
        try await harness.pump { $0.connectivity.isDisconnected }
        #expect(await harness.recorder.last?.rows.first?.metadata == nil)
        await harness.stop()
    }

    @Test func activityEventsRefetchTheSnapshotAndNeverMergeTheirOwnDetail() async throws {
        let harness = MetadataHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", task: "first")])
        await harness.start()
        try await harness.pump { $0.rows.first?.metadata?.task == "first" }
        await harness.settle()

        await harness.activity.setState([observed("alpha", "s1", task: "second")])
        await harness.activity.send(.agentActivity(
            seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: "pane", detail: "from the event")
        ))
        try await harness.pump { $0.rows.first?.metadata?.task == "second" }
        let tasks = await harness.recorder.values.flatMap(\.rows).compactMap(\.metadata?.task)
        #expect(!tasks.contains("from the event"))
        await harness.stop()
    }

    @Test func burstsOfActivityShareOneFetchInFlight() async throws {
        let harness = MetadataHarness(agents: [("alpha", "s1")], state: [observed("alpha", "s1", task: "first")])
        await harness.start()
        try await harness.pump { $0.rows.first?.metadata != nil }
        await harness.settle()
        let before = await harness.activity.fetchCount

        await harness.activity.holdNext()
        await harness.activity.send(.agentActivity(seq: 2, at: nil, agent: "alpha", activity: .working, currentAction: nil))
        try await harness.pumpAsync { _ in await harness.activity.heldCount == 1 }
        for seq in 3...6 {
            await harness.activity.send(.agentActivity(seq: seq, at: nil, agent: "alpha", activity: seq.isMultiple(of: 2) ? .idle : .working, currentAction: nil))
            await harness.settle()
        }
        #expect(await harness.activity.fetchCount == before + 1, "one in flight; the rest wait")
        await harness.activity.releaseHeld()
        try await harness.pumpAsync { _ in await harness.activity.fetchCount >= before + 2 }
        await harness.stop()
    }
}

private func observed(_ name: String, _ startedAt: String, task: String?) -> LeoObservedAgent {
    LeoObservedAgent(
        name: name, status: .running, activity: .idle, currentAction: task.map { .init(kind: "pane", detail: $0) },
        lastActivityAt: "2026-09-24T15:00:00Z", startedAt: startedAt
    )
}

private func agent(_ name: String, _ startedAt: String) -> LeoAgent {
    LeoAgent(
        name: name, template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running,
        startedAt: startedAt, restarts: nil, stoppedReason: nil, wakeOnMessage: nil
    )
}

private struct MetadataHarness {
    let clock = MetadataClock()
    let activity: MetadataActivity
    let daemon: MetadataDaemon
    let recorder = MetadataRecorder()
    let feed: LeoSidebarFeed

    init(agents: [(String, String)], state: [LeoObservedAgent]) {
        let activity = MetadataActivity(state: state)
        let daemon = MetadataDaemon(agents: agents)
        self.activity = activity
        self.daemon = daemon
        let clock = clock
        let recorder = recorder
        feed = LeoSidebarFeed(
            daemon: daemon,
            activity: .init(events: { await activity.events() }, fetchState: { await activity.fetchState() }),
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

    func pump(
        _ condition: @escaping @Sendable (LeoSidebarSnapshot) -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await pumpAsync(sourceLocation: sourceLocation) { snapshot in condition(snapshot) }
    }

    /// Fires pending sleeps until `condition` holds; the suite's time limit
    /// is the hang guard.
    func pumpAsync(
        sourceLocation: SourceLocation = #_sourceLocation, _ condition: @escaping @Sendable (LeoSidebarSnapshot) async -> Bool
    ) async throws {
        try await until(sourceLocation: sourceLocation) {
            if let last = await recorder.last, await condition(last) { return true }
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

private actor MetadataGate {
    private var holdsNext = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var heldCount: Int { held.count }

    func holdNext() { holdsNext = true }

    func pass() async {
        guard holdsNext else { return }
        holdsNext = false
        await withCheckedContinuation { held.append($0) }
    }

    func releaseHeld() {
        let pending = held
        held = []
        pending.forEach { $0.resume() }
    }
}

private actor MetadataActivity {
    private let stream: AsyncStream<LeoObserveEvent>
    private let continuation: AsyncStream<LeoObserveEvent>.Continuation
    private var state: [LeoObservedAgent]
    private let gate = MetadataGate()
    private(set) var fetchCount = 0

    init(state: [LeoObservedAgent]) {
        self.state = state
        (stream, continuation) = AsyncStream.makeStream()
    }

    var heldCount: Int { get async { await gate.heldCount } }
    func events() -> AsyncStream<LeoObserveEvent> { stream }
    func send(_ event: LeoObserveEvent) { continuation.yield(event) }
    func setState(_ state: [LeoObservedAgent]) { self.state = state }
    func holdNext() async { await gate.holdNext() }
    func releaseHeld() async { await gate.releaseHeld() }

    func fetchState() async -> [LeoObservedAgent] {
        fetchCount += 1
        let answer = state
        await gate.pass()
        return answer
    }
}

private actor MetadataDaemon: LeoDaemonClient {
    private var agents: [(String, String)]

    init(agents: [(String, String)]) { self.agents = agents }

    func setAgents(_ agents: [(String, String)]) { self.agents = agents }

    func listAgents() async throws -> [LeoAgent] { agents.map { agent($0.0, $0.1) } }

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

private actor MetadataRecorder {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    func append(_ value: LeoSidebarSnapshot) { values.append(value) }
}

private actor MetadataClock {
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
