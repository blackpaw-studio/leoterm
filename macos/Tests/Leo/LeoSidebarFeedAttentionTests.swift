import Foundation
import Testing

@testable import Ghostty

/// `LeoAttentionReducer` wired into `LeoSidebarFeed`: baselines from
/// `/state`, live commits through the injected sleeper, disconnect, focus,
/// host switch and the legacy fallback, all observed on emitted snapshots.
struct LeoSidebarFeedAttentionTests {
    @Test func baselineShowsBadgesAndDockCountWithoutTransitions() async throws {
        let harness = AttentionHarness(agents: ["alpha", "beta", "legacy"], state: [
            observed("alpha", attention: .init(state: .needsInput, revision: 4)),
            observed("beta", attention: .init(state: .working, revision: 2)),
            observed("legacy", activity: .working)
        ])
        await harness.start()

        await harness.waitFor { $0.rows.first { $0.name == "alpha" }?.attention == .needsInput }
        let snapshot = try #require(await harness.recorder.last)
        #expect(badges(snapshot) == ["alpha": .needsInput, "beta": .working, "legacy": .working])
        #expect(snapshot.attentionCount == 1)
        #expect(await harness.transitions.values.isEmpty)
        await harness.stop()
    }

    @Test func liveSignalCommitsThroughTheDeadlineAndReportsOneTransition() async throws {
        let harness = AttentionHarness(agents: ["alpha"], state: [observed("alpha", attention: .init(state: .working, revision: 1))])
        await harness.start()
        await harness.waitFor { $0.rows.first?.attention == .working }

        await harness.activity.send(.agentActivity(
            seq: 10, at: nil, agent: "alpha", activity: .idle, currentAction: nil,
            attention: .init(state: .finished, revision: 2)
        ))
        await harness.pump { $0.rows.first?.attention == .finished }

        #expect(await harness.recorder.last?.attentionCount == 1)
        await awaitCondition { await harness.transitions.values.count == 1 }
        #expect(await harness.transitions.values == [[.init(
            id: .init(host: .local, name: "alpha"), from: .working, to: .finished, revision: 2, shouldNotify: true
        )]])
        await harness.stop()
    }

    @Test func idleActivityNeverOverwritesSemanticWorking() async throws {
        let harness = AttentionHarness(agents: ["alpha"], state: [observed("alpha", attention: .init(state: .working, revision: 1))])
        await harness.start()
        await harness.waitFor { $0.rows.first?.attention == .working }

        await harness.activity.send(.agentActivity(seq: 10, at: nil, agent: "alpha", activity: .idle, currentAction: nil))
        await harness.pump { $0.rows.first?.activity == .idle }

        #expect(await harness.recorder.last?.rows.first?.attention == .working)
        await harness.stop()
    }

    @Test func disconnectHidesStaleBadgesAndClearsTheCount() async throws {
        let harness = AttentionHarness(agents: ["alpha"], state: [observed("alpha", attention: .init(state: .finished, revision: 1))])
        await harness.start()
        await harness.waitFor { $0.attentionCount == 1 }

        await harness.activity.send(.disconnected(reason: "EOF"))

        await harness.waitFor { $0.rows.first?.attention == nil && $0.attentionCount == 0 }
        await harness.stop()
    }

    @Test func focusingTheAgentAcknowledgesTheDockCountButKeepsTheBadge() async throws {
        let harness = AttentionHarness(agents: ["alpha"], state: [observed("alpha", attention: .init(state: .needsInput, revision: 1))])
        await harness.start()
        await harness.waitFor { $0.attentionCount == 1 }

        await harness.feed.setFocusedAgent(.init(host: .local, name: "alpha"))

        await harness.waitFor { $0.attentionCount == 0 && $0.rows.first?.attention == .needsInput }
        await harness.stop()
    }

    @Test func changedHelloBootIDReBaselinesWithoutKeepingAcknowledgements() async throws {
        let harness = AttentionHarness(agents: ["alpha"], state: [observed("alpha", attention: .init(state: .finished, revision: 1))])
        await harness.start()
        await harness.waitFor { $0.attentionCount == 1 }
        await harness.feed.setFocusedAgent(.init(host: .local, name: "alpha"))
        await harness.feed.setFocusedAgent(nil)
        await harness.waitFor { $0.attentionCount == 0 }
        let fetchesBefore = await harness.activity.fetchCount

        await harness.activity.send(.hello(seq: 1, at: nil, version: nil, serverTime: nil, bootID: "b1"))
        await harness.pumpAsync { _ in await harness.activity.fetchCount > fetchesBefore }
        await harness.activity.send(.hello(seq: 1, at: nil, version: nil, serverTime: nil, bootID: "b1"))
        let fetchesAfterSameBoot = await harness.activity.fetchCount
        await harness.pumpAsync { _ in await harness.activity.fetchCount > fetchesAfterSameBoot }
        #expect(await harness.recorder.last?.attentionCount == 0, "same boot_id is a normal reconnect")

        await harness.activity.send(.hello(seq: 1, at: nil, version: nil, serverTime: nil, bootID: "b2"))

        await harness.pump { $0.attentionCount == 1 }
        #expect(await harness.transitions.values.isEmpty, "restart baselines never notify")
        await harness.stop()
    }

    @Test func hostSwitchClearsBadgesAndCount() async throws {
        let harness = AttentionHarness(agents: ["alpha"], state: [observed("alpha", attention: .init(state: .errored, revision: 1))])
        await harness.start()
        await harness.waitFor { $0.attentionCount == 1 }

        await harness.feed.updateConnection(host: .remote("mars"), generation: 1, phase: .connecting)

        await harness.waitFor { $0.rows.isEmpty && $0.attentionCount == 0 }
        await harness.stop()
    }

    private func badges(_ snapshot: LeoSidebarSnapshot) -> [String: LeoAttentionBadge?] {
        Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.name, $0.attention) })
    }
}

private func observed(_ name: String, activity: LeoActivity = .idle, attention: LeoAttentionSignal? = nil) -> LeoObservedAgent {
    LeoObservedAgent(name: name, status: .running, activity: activity, currentAction: nil, lastActivityAt: nil, attention: attention)
}

private struct AttentionHarness {
    let clock = AttentionClock()
    let activity: AttentionActivity
    let recorder = AttentionRecorder<LeoSidebarSnapshot>()
    let transitions = AttentionRecorder<[LeoAttentionTransition]>()
    let feed: LeoSidebarFeed

    init(agents: [String], state: [LeoObservedAgent]) {
        let activity = AttentionActivity(state: state)
        self.activity = activity
        let daemon = AttentionDaemon(agents: agents.map {
            LeoAgent(name: $0, template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
        })
        let clock = clock
        let recorder = recorder
        let transitions = transitions
        feed = LeoSidebarFeed(
            daemon: daemon,
            activity: .init(events: { await activity.events() }, fetchState: { await activity.fetchState() }),
            sleep: { try await clock.sleep($0) },
            now: { 0 },
            onAttentionTransitions: { value in Task { await transitions.append(value) } },
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

    /// Fires pending sleeps until `condition` holds (see the coalescing tests).
    func pump(_ condition: @escaping @Sendable (LeoSidebarSnapshot) -> Bool) async {
        await pumpAsync { snapshot in condition(snapshot) }
    }

    func pumpAsync(_ condition: @escaping @Sendable (LeoSidebarSnapshot) async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let last = await recorder.last, await condition(last) { return }
            await clock.advanceAll()
            try? await Task.sleep(nanoseconds: 5_000_000)
        } while Date() < deadline
        Issue.record("Condition was not satisfied within 2 seconds")
    }
}

private actor AttentionActivity {
    private let stream: AsyncStream<LeoObserveEvent>
    private let continuation: AsyncStream<LeoObserveEvent>.Continuation
    private let state: [LeoObservedAgent]
    init(state: [LeoObservedAgent]) {
        self.state = state
        (stream, continuation) = AsyncStream.makeStream()
    }
    func events() -> AsyncStream<LeoObserveEvent> { stream }
    private(set) var fetchCount = 0
    func fetchState() -> [LeoObservedAgent] {
        fetchCount += 1
        return state
    }
    func send(_ event: LeoObserveEvent) { continuation.yield(event) }
}

private actor AttentionRecorder<Value: Sendable> {
    private(set) var values: [Value] = []
    var last: Value? { values.last }
    func append(_ value: Value) { values.append(value) }
}

private actor AttentionDaemon: LeoDaemonClient {
    private let agents: [LeoAgent]
    init(agents: [LeoAgent]) { self.agents = agents }
    func listAgents() async throws -> [LeoAgent] { agents }
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

/// Per-sleep manual clock (same shape as the coalescing tests' clock).
private actor AttentionClock {
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
