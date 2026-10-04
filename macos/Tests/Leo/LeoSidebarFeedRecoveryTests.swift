import Foundation
import Testing

@testable import Ghostty

@Suite(.timeLimit(.minutes(1)))
struct LeoSidebarFeedRecoveryTests {
    @Test @MainActor func runtimeDoesNotRetainSidebarModelThroughAttachHandler() {
        let daemon = RecoveryDaemon(agents: [])
        let activity = LeoActivityClient(config: .init(baseURL: URL(string: "http://127.0.0.1")!, token: "test"))
        weak var model: LeoSidebarModel?
        var runtime: LeoRuntime? = LeoRuntime(daemon: daemon, cli: .recordingForTests(), activity: activity, templateFetchRunner: LeoRecordingTemplateRunner())
        model = runtime?.model

        runtime = nil

        #expect(model == nil)
    }

    @Test func stateFailureDoesNotFailAgentList() async throws {
        let daemon = RecoveryDaemon(agents: [agent("alpha")])
        let recorder = RecoverySnapshotRecorder()
        let feed = LeoSidebarFeed(
            daemon: daemon,
            activity: .init(
                events: { AsyncStream { $0.finish() } },
                fetchState: { throw RecoveryError.unavailable }
            ),
            sink: { snapshot in Task { await recorder.append(snapshot) } }
        )

        await feed.start()
        await feed.setPolling(true)

        try await until { await recorder.last?.rows.map(\.name) == ["alpha"] }
        let snapshot = await recorder.last
        #expect(snapshot?.connectivity == .connected)
        #expect(snapshot?.rows.first?.activity == .unknown)
        await feed.stop()
    }

    @Test func suspendedStateFetchDoesNotBlockAgentList() async throws {
        let daemon = RecoveryDaemon(agents: [agent("alpha")])
        let suspendedState = SuspendedStateFetch()
        let recorder = RecoverySnapshotRecorder()
        let feed = LeoSidebarFeed(
            daemon: daemon,
            activity: .init(
                events: { AsyncStream { $0.finish() } },
                fetchState: { try await suspendedState.fetch(); return [] }
            ),
            sink: { snapshot in Task { await recorder.append(snapshot) } }
        )

        await feed.start()
        await feed.setPolling(true)

        try await until { await suspendedState.isSuspended }
        try await until { await recorder.last?.rows.map(\.name) == ["alpha"] }
        #expect(await recorder.last?.connectivity == .connected)
        await feed.stop()
        try await until { await suspendedState.wasCancelled }
    }

    @Test @MainActor func startingAfterRegisteringVisibleSessionRefreshesImmediately() async throws {
        let daemon = RecoveryDaemon(agents: [agent("alpha")])
        // Parallel test hosts share one preferences domain per name.
        let defaults = LeoInMemoryDefaults()
        // An inert stream, as below: a real client to a closed port reports
        // a dead stream, which disconnects the feed (D-061) and can beat
        // the first refresh.
        let activity = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(daemon: daemon, cli: .recordingForTests(), activitySource: activity, defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner())
        let session = runtime.makeWindowSession()
        // The sidebar is hidden by default on a fresh install -- this test
        // is specifically about *visible*-sidebar pollability, so state
        // that precondition explicitly rather than relying on the default.
        session.setSidebarVisible(true)

        runtime.start()

        try await eventually { await daemon.listCallCount == 1 }
        #expect(session.isPollable)
        runtime.shutdown()
    }

    /// A window with its sidebar hidden (the default) must still refresh
    /// the agent list the moment its palette is presented -- otherwise the
    /// palette shows whatever stale/empty snapshot happened to exist before
    /// the user opened it. Mirrors
    /// `startingAfterRegisteringVisibleSessionRefreshesImmediately`, but
    /// drives pollability through `setPickerPresented(_:)` instead of
    /// sidebar visibility.
    @Test @MainActor func presentingPickerWithHiddenSidebarRefreshesImmediately() async throws {
        let daemon = RecoveryDaemon(agents: [agent("alpha")])
        let defaults = LeoInMemoryDefaults()
        // An inert stream: a dead one would (rightly) disconnect the feed
        // and stop all refreshes (D-061), which is not what this is about.
        let activity = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(daemon: daemon, cli: .recordingForTests(), activitySource: activity, defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner())
        let session = runtime.makeWindowSession()

        runtime.start()
        try await eventually { await daemon.listCallCount == 1 }
        #expect(!session.isSidebarVisible)
        #expect(!session.isPollable)

        session.setPickerPresented(true)

        try await eventually { await daemon.listCallCount == 2 }
        #expect(session.isPollable)
        runtime.shutdown()
    }

    private func agent(_ name: String) -> LeoAgent {
        .init(name: name, template: "default", repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        try await until { await condition() }
    }
}

private enum RecoveryError: Error { case unavailable }

private actor RecoveryDaemon: LeoDaemonClient {
    let agents: [LeoAgent]
    private(set) var listCallCount = 0

    init(agents: [LeoAgent]) { self.agents = agents }

    func listAgents() async throws -> [LeoAgent] { listCallCount += 1; return agents }
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

private actor RecoverySnapshotRecorder {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    func append(_ snapshot: LeoSidebarSnapshot) { values.append(snapshot) }
}

private actor SuspendedStateFetch {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isSuspended = false
    private(set) var wasCancelled = false

    func fetch() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                isSuspended = true
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        wasCancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
