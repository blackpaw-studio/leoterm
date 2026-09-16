import Foundation
import Testing

@testable import Ghostty

struct LeoSidebarFeedTests {
    @Test func visibleSidebarImmediatelyFetchesAndPublishesRows() async throws {
        let daemon = FakeDaemonClient(results: [.success([agent("alpha")])])
        let recorder = SnapshotRecorder()
        let feed = makeFeed(daemon: daemon, recorder: recorder)

        await feed.start()
        await feed.setPolling(true)
        try await eventually {
            let calls = await daemon.listCallCount
            let snapshot = await recorder.last
            return calls == 1 && snapshot?.rows.map(\.name) == ["alpha"]
        }
        let snapshot = await recorder.last
        #expect(snapshot?.connectivity == .connected)
        await feed.stop()
    }

    @Test func failedListRetainsPreviousRows() async throws {
        let daemon = FakeDaemonClient(results: [.success([agent("alpha")]), .failure(TestError("unavailable"))])
        let recorder = SnapshotRecorder()
        let feed = makeFeed(daemon: daemon, recorder: recorder)

        await feed.start(); await feed.setPolling(true)
        try await eventually { await recorder.last?.connectivity == .connected }
        await feed.refresh()
        try await eventually { if case .failed(let message) = await recorder.last?.connectivity { return message.contains("unavailable") }; return false }
        let snapshot = await recorder.last
        #expect(snapshot?.rows.map(\.name) == ["alpha"])
        await feed.stop()
    }

    @Test func structuralEventsCoalesceRefreshes() async throws {
        let daemon = FakeDaemonClient(results: [.success([agent("alpha")])])
        let recorder = SnapshotRecorder()
        let feed = makeFeed(daemon: daemon, recorder: recorder)

        await feed.start(); await feed.setPolling(true)
        try await eventually { await daemon.listCallCount == 1 }
        await feed.receive(.agentSpawned(seq: 1, at: nil, agent: agent("bravo")))
        await feed.receive(.agentStopped(seq: 2, at: nil, agent: "alpha", wakeOnMessage: nil))
        try await eventually { await daemon.listCallCount == 2 }
        await feed.receive(.agentStateChanged(seq: 3, at: nil, agent: "alpha", status: .stopped, restarts: nil, wakeOnMessage: nil))
        let calls = await daemon.listCallCount
        #expect(calls == 2)
        await daemon.resolveNext(.success([agent("charlie")]))
        try await eventually { await daemon.listCallCount == 3 }
        await daemon.resolveNext(.success([agent("delta")]))
        try await eventually { await recorder.last?.rows.map(\.name) == ["delta"] }
        await feed.stop()
    }

    @Test func activityEventUpdatesOverlayWithoutListRefresh() async throws {
        let daemon = FakeDaemonClient(results: [.success([agent("alpha")])])
        let recorder = SnapshotRecorder()
        let feed = makeFeed(daemon: daemon, recorder: recorder)

        await feed.start(); await feed.setPolling(true)
        try await eventually { await recorder.last?.connectivity == .connected }
        await feed.receive(.agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: "tool", detail: "building")))
        try await eventually { await recorder.last?.rows.first?.activity == .working }
        let calls = await daemon.listCallCount
        let snapshot = await recorder.last
        #expect(calls == 1)
        #expect(snapshot?.rows.first?.actionDetail == "building")
        await feed.stop()
    }

    @Test func gapRecoversStateAndReplaysBufferedActivity() async throws {
        let daemon = FakeDaemonClient(results: [.success([agent("alpha")])])
        let activity = FakeActivitySource()
        let recorder = SnapshotRecorder()
        let feed = makeFeed(daemon: daemon, activity: activity, recorder: recorder)

        await feed.start(); await feed.setPolling(true)
        try await eventually { await recorder.last?.connectivity == .connected }
        let baselineFetches = await activity.fetchCount
        await feed.receive(.gap(expected: 4, received: 5))
        try await eventually { await daemon.listCallCount == 2 }
        await feed.receive(.agentActivity(seq: 6, at: nil, agent: "alpha", activity: .working, currentAction: .init(kind: nil, detail: "replayed")))
        await daemon.resolveNext(.success([agent("alpha")]))
        try await eventually { await recorder.last?.rows.first?.actionDetail == "replayed" }
        let fetchCount = await activity.fetchCount
        #expect(fetchCount == baselineFetches + 1)
        await feed.stop()
    }

    @Test func disconnectClearsActivityWhileRetainingRows() async throws {
        let daemon = FakeDaemonClient(results: [.success([agent("alpha")])])
        let recorder = SnapshotRecorder()
        let feed = makeFeed(daemon: daemon, recorder: recorder)

        await feed.start(); await feed.setPolling(true)
        try await eventually { await recorder.last?.connectivity == .connected }
        await feed.receive(.agentActivity(seq: 1, at: nil, agent: "alpha", activity: .working, currentAction: nil))
        try await eventually { await recorder.last?.rows.first?.activity == .working }
        await feed.receive(.disconnected(reason: "EOF"))
        try await eventually { await recorder.last?.rows.first?.activity == .unknown }
        let snapshot = await recorder.last
        #expect(snapshot?.rows.map(\.name) == ["alpha"])
        await feed.stop()
    }

    @Test func staleGenerationListResultIsDiscarded() async throws {
        let daemon = FakeDaemonClient(results: [.success([agent("alpha")])])
        let recorder = SnapshotRecorder()
        let feed = makeFeed(daemon: daemon, recorder: recorder)

        await feed.start(); await feed.setPolling(true)
        try await eventually { await recorder.last?.rows.map(\.name) == ["alpha"] }
        await feed.refresh()
        try await eventually { await daemon.listCallCount == 2 }
        await feed.receive(.gap(expected: 2, received: 3))
        await daemon.resolveNext(.success([agent("stale")]))
        try await eventually { await daemon.listCallCount == 3 }
        await daemon.resolveNext(.success([agent("fresh")]))
        try await eventually { await recorder.last?.rows.map(\.name) == ["fresh"] }
        let snapshots = await recorder.values
        #expect(!snapshots.contains { $0.rows.map(\.name) == ["stale"] })
        await feed.stop()
    }

    @Test func pollingOnlyRunsWhileSidebarIsVisible() async throws {
        let daemon = FakeDaemonClient(results: [.success([agent("alpha")])])
        let recorder = SnapshotRecorder()
        let feed = makeFeed(daemon: daemon, recorder: recorder)

        await feed.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        var calls = await daemon.listCallCount
        #expect(calls == 0)
        await feed.setPolling(true)
        try await eventually { await daemon.listCallCount == 1 }
        await feed.setPolling(false)
        try await Task.sleep(nanoseconds: 20_000_000)
        calls = await daemon.listCallCount
        #expect(calls == 1)
        await feed.stop()
    }

    @Test func stopSuppressesPendingRefreshResult() async throws {
        let daemon = FakeDaemonClient()
        let recorder = SnapshotRecorder()
        let feed = makeFeed(daemon: daemon, recorder: recorder)

        await feed.start(); await feed.setPolling(true)
        try await eventually { await daemon.listCallCount == 1 }
        await feed.stop()
        await daemon.resolveNext(.success([agent("late")]))
        try await Task.sleep(nanoseconds: 20_000_000)
        let snapshots = await recorder.values
        #expect(snapshots.isEmpty)
    }

    private func makeFeed(daemon: FakeDaemonClient, activity: FakeActivitySource = .init(), recorder: SnapshotRecorder) -> LeoSidebarFeed {
        LeoSidebarFeed(daemon: daemon, activity: .init(events: { await activity.events() }, fetchState: { await activity.fetchState() })) { snapshot in
            Task { await recorder.append(snapshot) }
        }
    }

    private func agent(_ name: String) -> LeoAgent {
        .init(name: name, template: "default", repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<40 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Condition was not satisfied")
    }
}

private actor SnapshotRecorder {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    func append(_ snapshot: LeoSidebarSnapshot) { values.append(snapshot) }
}

private actor FakeActivitySource {
    private let stream: AsyncStream<LeoObserveEvent>
    private let continuation: AsyncStream<LeoObserveEvent>.Continuation
    private(set) var fetchCount = 0
    private var state: [LeoObservedAgent] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func events() -> AsyncStream<LeoObserveEvent> { stream }
    func fetchState() -> [LeoObservedAgent] { fetchCount += 1; return state }
}

private actor FakeDaemonClient: LeoDaemonClient {
    private var results: [Result<[LeoAgent], Error>]
    private var waiters: [CheckedContinuation<Result<[LeoAgent], Error>, Never>] = []
    private(set) var listCallCount = 0

    init(results: [Result<[LeoAgent], Error>] = []) { self.results = results }

    func listAgents() async throws -> [LeoAgent] {
        listCallCount += 1
        if !results.isEmpty { return try results.removeFirst().get() }
        return try await withCheckedContinuation { waiters.append($0) }.get()
    }

    func resolveNext(_ result: Result<[LeoAgent], Error>) {
        waiters.removeFirst().resume(returning: result)
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

private struct TestError: Error, CustomStringConvertible, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
