import Foundation
import Testing

@testable import Ghostty

struct LeoSidebarFeedRecoveryTests {
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

        try await eventually { await recorder.last?.rows.map(\.name) == ["alpha"] }
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

        try await eventually { await recorder.last?.rows.map(\.name) == ["alpha"] }
        #expect(await recorder.last?.connectivity == .connected)
        try await eventually { await suspendedState.started }
        await feed.stop()
        try await eventually { await suspendedState.wasCancelled }
    }

    @Test @MainActor func startingAfterRegisteringVisibleSessionRefreshesImmediately() async throws {
        let daemon = RecoveryDaemon(agents: [agent("alpha")])
        let defaults = UserDefaults(suiteName: "LeoSidebarFeedRecoveryTests")!
        defaults.removePersistentDomain(forName: "LeoSidebarFeedRecoveryTests")
        let activity = LeoActivityClient(config: .init(baseURL: URL(string: "http://127.0.0.1")!, token: "test"))
        let runtime = LeoRuntime(daemon: daemon, cli: LeoCLI(), activity: activity, defaults: defaults)
        let session = runtime.makeWindowSession()

        runtime.start()

        try await eventually { await daemon.listCallCount == 1 }
        #expect(session.isPollable)
        runtime.shutdown()
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
    private(set) var started = false
    private(set) var wasCancelled = false

    func fetch() async throws {
        started = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
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
