import Foundation
import Testing

@testable import Ghostty

/// Fetches that answer for an older moment than they land in: a list or
/// `/state` fetch still in flight across a daemon restart or an
/// `agent_spawned`. Each fake answers with the daemon's data as of the call
/// and can hold the answer back.
struct LeoSidebarFeedAttentionRaceTests {
    @Test func helloWithANewBootIDWhileTheOldFetchIsStillInFlight() async throws {
        let harness = RaceHarness(agents: ["alpha"], state: [observed("alpha", .working, 1)])
        await harness.start()
        await harness.waitFor { $0.rows.first?.attention == .working }
        await harness.activity.send(.hello(seq: 1, at: nil, version: nil, serverTime: nil, bootID: "boot-a"))
        await harness.pumpAsync { _ in await harness.activity.fetchCount >= 2 }
        await harness.settle()

        // A recovery's /state is answered by the old daemon but held back.
        await harness.activity.setState([observed("alpha", .needsInput, 40)])
        await harness.activity.holdNext()
        await harness.activity.send(.gap(expected: 2, received: 5))
        await harness.pumpAsync { _ in await harness.activity.heldCount == 1 }

        // The daemon restarts; the new boot's first hello arrives.
        await harness.activity.setState([observed("alpha", .working, 2)])
        await harness.activity.send(.disconnected(reason: "EOF"))
        await harness.activity.send(.hello(seq: 1, at: nil, version: nil, serverTime: nil, bootID: "boot-b"))
        await harness.pump { $0.rows.first?.attention == .working }
        await harness.activity.releaseHeld()
        await harness.settle()

        let snapshot = try #require(await harness.recorder.last)
        #expect(snapshot.rows.first?.attention == .working, "the old boot's needs_input must never land")
        #expect(snapshot.attentionCount == 0)
        await harness.stop()
    }

    @Test func helloWithANewBootIDWhileARecoveryListIsStillInFlight() async throws {
        let harness = RaceHarness(agents: ["alpha"], state: [observed("alpha", .working, 1)])
        await harness.start()
        await harness.waitFor { $0.rows.first?.attention == .working }
        await harness.activity.send(.hello(seq: 1, at: nil, version: nil, serverTime: nil, bootID: "boot-a"))
        await harness.pumpAsync { _ in await harness.activity.fetchCount >= 2 }
        await harness.settle()

        await harness.activity.setState([observed("alpha", .needsInput, 40)])
        await harness.daemon.holdNext()
        await harness.activity.send(.gap(expected: 2, received: 5))
        await harness.pumpAsync { _ in await harness.daemon.heldCount == 1 }

        // Restart while the feed is still recovering (the list hasn't landed).
        await harness.activity.setState([observed("alpha", .working, 2)])
        await harness.activity.send(.disconnected(reason: "EOF"))
        await harness.activity.send(.hello(seq: 1, at: nil, version: nil, serverTime: nil, bootID: "boot-b"))
        await harness.daemon.releaseHeld()
        await harness.settle()

        let snapshot = try #require(await harness.recorder.last)
        #expect(snapshot.rows.first?.attention == .working)
        #expect(snapshot.attentionCount == 0)
        await harness.stop()
    }

    @Test func aListFetchedBeforeAgentSpawnedKeepsTheSpawnedAgentsAttention() async throws {
        let harness = RaceHarness(agents: ["alpha"], state: [observed("alpha", .working, 1)])
        await harness.start()
        await harness.waitFor { $0.rows.first?.attention == .working }
        await harness.settle()

        // A list refresh answered before beta existed is held back.
        await harness.daemon.holdNext()
        await harness.activity.send(.agentStateChanged(seq: 2, at: nil, agent: "alpha", status: .running, restarts: nil, wakeOnMessage: nil))
        await harness.pumpAsync { _ in await harness.daemon.heldCount == 1 }

        await harness.daemon.setAgents(["alpha", "beta"])
        await harness.activity.send(.agentSpawned(seq: 3, at: nil, agent: agent("beta"), attention: .init(state: .unknown, revision: 1)))
        await harness.activity.send(.agentActivity(seq: 4, at: nil, agent: "beta", activity: .working, currentAction: nil))
        await harness.daemon.releaseHeld()
        await harness.pump { $0.rows.map(\.name) == ["alpha", "beta"] && $0.rows.last?.activity == .working }
        await harness.settle()

        let beta = try #require(await harness.recorder.last?.rows.last)
        #expect(beta.attention == nil, "the daemon said unknown; no invented legacy Working")
        await harness.stop()
    }
}

private func observed(_ name: String, _ state: LeoAttentionState, _ revision: Int) -> LeoObservedAgent {
    LeoObservedAgent(
        name: name, status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil,
        attention: .init(state: state, revision: revision)
    )
}

private func agent(_ name: String) -> LeoAgent {
    LeoAgent(
        name: name, template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running,
        startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil
    )
}

private struct RaceHarness {
    let clock = RaceClock()
    let activity: RaceActivity
    let daemon: RaceDaemon
    let recorder = RaceRecorder()
    let feed: LeoSidebarFeed

    init(agents: [String], state: [LeoObservedAgent]) {
        let activity = RaceActivity(state: state)
        let daemon = RaceDaemon(agents: agents)
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

    func waitFor(_ condition: @escaping @Sendable (LeoSidebarSnapshot) -> Bool) async {
        await awaitCondition { await recorder.last.map(condition) ?? false }
    }

    func pump(
        _ condition: @escaping @Sendable (LeoSidebarSnapshot) -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await pumpAsync(sourceLocation: sourceLocation) { snapshot in condition(snapshot) }
    }

    func pumpAsync(
        sourceLocation: SourceLocation = #_sourceLocation, _ condition: @escaping @Sendable (LeoSidebarSnapshot) async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let last = await recorder.last, await condition(last) { return }
            await clock.advanceAll()
            try? await Task.sleep(nanoseconds: 5_000_000)
        } while Date() < deadline
        Issue.record("Condition was not satisfied within 2 seconds", sourceLocation: sourceLocation)
    }

    /// Fires every pending sleep a few times so follow-up refreshes and
    /// commit deadlines run.
    func settle() async {
        for _ in 0..<8 {
            await clock.advanceAll()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Holds answers back: each held call answers with the data as of the call.
private actor RaceGate {
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

private actor RaceActivity {
    private let stream: AsyncStream<LeoObserveEvent>
    private let continuation: AsyncStream<LeoObserveEvent>.Continuation
    private var state: [LeoObservedAgent]
    private let gate = RaceGate()
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

private actor RaceDaemon: LeoDaemonClient {
    private var agents: [String]
    private let gate = RaceGate()

    init(agents: [String]) { self.agents = agents }

    var heldCount: Int { get async { await gate.heldCount } }
    func setAgents(_ agents: [String]) { self.agents = agents }
    func holdNext() async { await gate.holdNext() }
    func releaseHeld() async { await gate.releaseHeld() }

    func listAgents() async throws -> [LeoAgent] {
        let answer = agents.map(agent)
        await gate.pass()
        return answer
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

private actor RaceRecorder {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    func append(_ value: LeoSidebarSnapshot) { values.append(value) }
}

private actor RaceClock {
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
