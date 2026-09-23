import Foundation
import Testing

@testable import Ghostty

/// Attention recovery through failures and host switches: a failed list or
/// `/state` fetch leaves the baseline pending for the next refresh (never a
/// timer), and events from a superseded connection are dropped.
struct LeoSidebarFeedAttentionRecoveryTests {
    private static let needsInput = LeoObservedAgent(
        name: "alpha", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil,
        attention: .init(state: .needsInput, revision: 1)
    )

    @Test func failedListFetchLeavesTheStateBaselinePendingForTheNextRefresh() async {
        let harness = RecoveryHarness(listFailures: 1, stateFailures: 0, state: [Self.needsInput])
        await harness.start()
        await awaitCondition { await harness.recorder.last.map { if case .failed = $0.connectivity { true } else { false } } ?? false }
        #expect(await harness.activity.fetchCount == 0)

        await harness.feed.refresh()

        await harness.waitFor { $0.rows.first?.attention == .needsInput }
        await harness.stop()
    }

    @Test func failedStateFetchIsRetriedByTheNextRefresh() async {
        let harness = RecoveryHarness(listFailures: 0, stateFailures: 1, state: [Self.needsInput])
        await harness.start()
        await awaitCondition { await harness.activity.fetchCount == 1 }
        await harness.waitFor { $0.rows.map(\.name) == ["alpha"] }

        await harness.feed.refresh()

        await harness.waitFor { $0.rows.first?.attention == .needsInput }
        #expect(await harness.activity.fetchCount == 2)
        await harness.stop()
    }

    @Test func withSSEConnectedTheNextPollTickRetriesAFailedStateFetch() async {
        let working = LeoObservedAgent(
            name: "alpha", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil,
            attention: .init(state: .working, revision: 1)
        )
        let harness = RecoveryHarness(listFailures: 0, stateFailures: 2, state: [working])
        await harness.start()
        await awaitCondition { await harness.activity.fetchCount == 1 }
        await harness.waitFor { $0.rows.map(\.name) == ["alpha"] }

        await harness.feed.receive(.connected)
        await awaitCondition { await harness.activity.fetchCount == 2 }
        await harness.feed.receive(
            .agentActivity(seq: 2, at: nil, agent: "alpha", activity: .idle, currentAction: nil, attention: .init(state: .needsInput, revision: 2))
        )
        await harness.settle()

        #expect(await harness.activity.fetchCount == 3, "a poll tick retries /state while SSE is connected")
        await harness.waitFor { $0.rows.first?.attention == .needsInput }
        await harness.stop()
    }

    @Test func eventsFromASupersededConnectionAreDropped() async {
        let harness = RecoveryHarness(listFailures: 0, stateFailures: 0, state: [Self.needsInput])
        await harness.start()
        await harness.waitFor { $0.rows.first?.attention == .needsInput }
        let staleGeneration = await harness.feed.connectionGeneration
        await harness.feed.updateConnection(
            host: .remote("mars"), generation: staleGeneration + 1,
            phase: .connected(daemon: harness.daemon, activitySource: harness.activitySource)
        )
        await harness.waitFor { $0.rows.first?.host == .remote("mars") && $0.rows.first?.attention == .needsInput }
        let fetches = await harness.activity.fetchCount

        await harness.feed.receive(
            .agentActivity(seq: 9, at: nil, agent: "alpha", activity: .idle, currentAction: nil, attention: .init(state: .errored, revision: 9)),
            generation: staleGeneration
        )
        await harness.feed.receive(.hello(seq: 1, at: nil, version: nil, serverTime: nil, bootID: "old"), generation: staleGeneration)
        await harness.settle()

        #expect(await harness.recorder.last?.rows.first?.attention == .needsInput)
        #expect(await harness.activity.fetchCount == fetches, "a stale hello must not start a recovery")
        await harness.stop()
    }
}

private struct RecoveryHarness {
    let clock = ManualClock()
    let activity: ScriptedActivity
    let daemon: ScriptedDaemon
    let recorder = SnapshotLog()
    let feed: LeoSidebarFeed
    var activitySource: LeoSidebarActivitySource {
        .init(events: { await activity.events() }, fetchState: { try await activity.fetchState() })
    }

    init(listFailures: Int, stateFailures: Int, state: [LeoObservedAgent]) {
        let activity = ScriptedActivity(failures: stateFailures, state: state)
        let daemon = ScriptedDaemon(failures: listFailures)
        self.activity = activity
        self.daemon = daemon
        let clock = clock
        let recorder = recorder
        feed = LeoSidebarFeed(
            daemon: daemon,
            activity: .init(events: { await activity.events() }, fetchState: { try await activity.fetchState() }),
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

    /// Fires every pending sleep a few times so anything a stale event would
    /// have scheduled (a coalesced refresh, a commit deadline) gets to run.
    func settle() async {
        for _ in 0..<5 {
            await clock.advanceAll()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum ScriptedFailure: Error { case unavailable }

private actor ScriptedActivity {
    private let stream: AsyncStream<LeoObserveEvent>
    private var failures: Int
    private let state: [LeoObservedAgent]
    private(set) var fetchCount = 0

    init(failures: Int, state: [LeoObservedAgent]) {
        self.failures = failures
        self.state = state
        stream = AsyncStream { _ in }
    }

    func events() -> AsyncStream<LeoObserveEvent> { stream }

    func fetchState() throws -> [LeoObservedAgent] {
        fetchCount += 1
        guard failures == 0 else {
            failures -= 1
            throw ScriptedFailure.unavailable
        }
        return state
    }
}

private actor SnapshotLog {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    func append(_ value: LeoSidebarSnapshot) { values.append(value) }
}

private actor ScriptedDaemon: LeoDaemonClient {
    private var failures: Int
    init(failures: Int) { self.failures = failures }
    func listAgents() async throws -> [LeoAgent] {
        guard failures == 0 else {
            failures -= 1
            throw ScriptedFailure.unavailable
        }
        return [LeoAgent(
            name: "alpha", template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running,
            startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil
        )]
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

private actor ManualClock {
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
