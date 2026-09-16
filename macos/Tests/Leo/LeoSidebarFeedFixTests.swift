import Foundation
import Testing

@testable import Ghostty

struct LeoSidebarFeedFixTests {
    @Test func helloAfterConnectedCoalescesRecoveryRefresh() async throws {
        let daemon = FeedFixDaemon(results: [[agent("alpha")], [agent("bravo")], [agent("charlie")]])
        let activity = FeedFixActivity()
        let recorder = FeedFixRecorder()
        let feed = makeFeed(daemon: daemon, activity: activity, recorder: recorder)

        await feed.start()
        await feed.setPolling(true)
        try await wait {
            let calls = await daemon.listCallCount
            let fetches = await activity.fetchCount
            return calls == 1 && fetches == 1
        }
        await activity.send(.connected)
        await activity.send(.hello(seq: 1, at: nil, version: nil, serverTime: nil))
        try await wait {
            let calls = await daemon.listCallCount
            let fetches = await activity.fetchCount
            return calls == 2 && fetches == 2
        }
        try await wait {
            let calls = await daemon.listCallCount
            let fetches = await activity.fetchCount
            return calls == 2 && fetches == 2
        }
        #expect(await daemon.listCallCount == 2)
        #expect(await activity.fetchCount == 2)
        await feed.stop()
    }

    @Test func stoppingSuspendedListDoesNotScheduleFollowUpOrEmit() async throws {
        let daemon = FeedFixDaemon()
        let recorder = FeedFixRecorder()
        let feed = makeFeed(daemon: daemon, activity: FeedFixActivity(), recorder: recorder)

        await feed.start()
        await feed.setPolling(true)
        try await wait { await daemon.listCallCount == 1 }
        await feed.refresh()
        await feed.stop()
        await daemon.resolveNext([agent("late")])
        try await wait {
            let calls = await daemon.listCallCount
            let values = await recorder.values
            return calls == 1 && values.isEmpty
        }
        #expect(await daemon.listCallCount == 1)
        #expect(await recorder.values.isEmpty)
    }

    @Test func listTimeoutRetainsRowsAndSubsequentTickRefreshes() async throws {
        let clock = FeedFixClock()
        let daemon = NonCooperativeFeedFixDaemon(results: [[agent("alpha")]])
        let recorder = FeedFixRecorder()
        let feed = makeFeed(daemon: daemon, activity: FeedFixActivity(), recorder: recorder, sleep: { try await clock.sleep($0) })

        await feed.start()
        await feed.setPolling(true)
        try await wait { await recorder.last?.rows.map(\.name) == ["alpha"] }
        await feed.refresh()
        try await wait {
            let calls = await daemon.listCallCount
            let sleeps = await clock.sleepCount
            return calls == 2 && sleeps > 0
        }
        await clock.advanceAll()
        try await wait {
            if case .failed(let message) = await recorder.last?.connectivity { return message == "timed out" }
            return false
        }
        #expect(await recorder.last?.rows.map(\.name) == ["alpha"])
        await feed.tick()
        try await wait { await daemon.listCallCount == 3 }
        await daemon.resolvePending(at: 0, with: [agent("stale")])
        await daemon.resolvePending(at: 0, with: [agent("bravo")])
        try await wait { await recorder.last?.rows.map(\.name) == ["bravo"] }
        #expect(!(await recorder.values).contains { $0.rows.map(\.name) == ["stale"] })
        await feed.stop()
    }

    @Test func stopReleasesFeedWhenEventsNeverFinish() async throws {
        let activity = FeedFixActivity()
        var feed: LeoSidebarFeed? = makeFeed(daemon: FeedFixDaemon(), activity: activity, recorder: FeedFixRecorder())
        weak var reference = feed
        await feed?.start()
        await feed?.stop()
        feed = nil
        #expect(reference == nil)
        #expect(reference == nil)
    }

    @Test func selectedHostErrorPausesPollingUntilConnected() async throws {
        let daemon = FeedFixDaemon(results: [[agent("alpha")], [agent("bravo")]])
        let recorder = FeedFixRecorder()
        let feed = makeFeed(daemon: daemon, activity: FeedFixActivity(), recorder: recorder)
        let host = LeoHostID.remote("work")
        await feed.start()
        await feed.select(host)
        await feed.setPolling(true)
        try await wait { await recorder.last?.connectivity == .connected }
        await feed.receive(.hostStateChanged(.init(name: "work", ssh: "evan@work", state: .error,
                                                   error: "Permission denied (publickey)", code: "ssh_auth_required")))
        try await wait {
            if case .failed(let message) = await recorder.last?.connectivity { return message.contains("Permission denied") }
            return false
        }
        let pausedCalls = await daemon.listCallCount
        await feed.tick()
        await feed.tick()
        #expect(await daemon.listCallCount == pausedCalls)
        await feed.receive(.hostStateChanged(.init(name: "work", state: .connected)))
        try await wait { await daemon.listCallCount == pausedCalls + 1 }
        await feed.stop()
    }

    private func makeFeed(daemon: some LeoDaemonClient, activity: FeedFixActivity, recorder: FeedFixRecorder, sleep: (@Sendable (UInt64) async throws -> Void)? = nil) -> LeoSidebarFeed {
        let source = LeoSidebarActivitySource(events: { await activity.events() }, fetchState: { await activity.fetchState() })
        let sink: LeoSidebarFeed.Sink = { snapshot in Task { await recorder.append(snapshot) } }
        if let sleep {
            return LeoSidebarFeed(daemon: daemon, activity: source, sleep: sleep, sink: sink)
        }
        return LeoSidebarFeed(daemon: daemon, activity: source, sink: sink)
    }

    private func agent(_ name: String) -> LeoAgent {
        .init(name: name, template: "default", repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
    }

    private func wait(_ condition: @escaping @Sendable () async -> Bool) async throws {
        await awaitCondition(condition)
    }
}

private actor NonCooperativeFeedFixDaemon: LeoDaemonClient {
    private var results: [[LeoAgent]]
    private var waiters: [CheckedContinuation<[LeoAgent], Never>] = []
    private(set) var listCallCount = 0

    init(results: [[LeoAgent]] = []) { self.results = results }
    func listAgents() async throws -> [LeoAgent] {
        listCallCount += 1
        if !results.isEmpty { return results.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func resolvePending(at index: Int, with agents: [LeoAgent]) {
        waiters.remove(at: index).resume(returning: agents)
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

private actor FeedFixDaemon: LeoDaemonClient {
    private var results: [[LeoAgent]]
    private var waiters: [CheckedContinuation<Result<[LeoAgent], Error>, Never>] = []
    private(set) var listCallCount = 0

    init(results: [[LeoAgent]] = []) { self.results = results }
    func listAgents() async throws -> [LeoAgent] {
        listCallCount += 1
        if !results.isEmpty { return results.removeFirst() }
        return try await withTaskCancellationHandler {
            try await withCheckedContinuation { waiters.append($0) }.get()
        } onCancel: {
            Task { await self.cancelPending() }
        }
    }
    func resolveNext(_ result: [LeoAgent]) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: .success(result))
    }
    private func cancelPending() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: .failure(CancellationError())) }
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

private actor FeedFixActivity {
    private let stream: AsyncStream<LeoObserveEvent>
    private let continuation: AsyncStream<LeoObserveEvent>.Continuation
    private(set) var fetchCount = 0
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func events() -> AsyncStream<LeoObserveEvent> { stream }
    func fetchState() -> [LeoObservedAgent] { fetchCount += 1; return [] }
    func send(_ event: LeoObserveEvent) { continuation.yield(event) }
}

private actor FeedFixRecorder {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    func append(_ snapshot: LeoSidebarSnapshot) { values.append(snapshot) }
}

private actor FeedFixClock {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    var sleepCount: Int { waiters.count }
    func sleep(_ nanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append($0) }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }
    func advanceAll() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    private func cancelAll() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}
