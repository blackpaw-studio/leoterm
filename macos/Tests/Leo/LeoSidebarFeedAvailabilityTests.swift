import Foundation
import Testing

@testable import Ghostty

/// `refresh()` and `tick()` both guard on `selectedHostAvailable`, but
/// SSE-driven structural events (agent spawned/stopped/state-changed, hello,
/// gap, snapshot, connected) reached the scheduler directly through
/// `process(scheduler.reduce(.sseEvent(event)))`, bypassing that guard
/// entirely. After a selected host fails, an SSE event for that same host
/// could still kick off a refresh -- and, if it happened to land after the
/// failure was published, overwrite the `.failed` connectivity state.
struct LeoSidebarFeedAvailabilityTests {
    @Test func sseEventForAFailedHostDoesNotTriggerARefreshOrOverwriteFailedState() async throws {
        let daemon = CountingDaemonClient()
        let recorder = SnapshotRecorder()
        let feed = LeoSidebarFeed(
            daemon: daemon,
            activity: .init(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        ) { snapshot in
            Task { await recorder.append(snapshot) }
        }

        await feed.start()
        await feed.setPolling(true)
        await awaitCondition(message: "Initial local refresh was not requested") { await daemon.listCallCount >= 1 }

        await feed.select(.remote("work"))
        await awaitCondition(message: "Refresh for the newly selected host was not requested") { await daemon.listCallCount >= 2 }

        // The selected host errors out.
        await feed.receive(.hostStateChanged(.init(name: "work", local: false, state: .error, error: "boom", code: "ssh_auth_required")))
        await awaitCondition(message: "Connectivity did not become .failed") {
            if case .failed = await recorder.last?.connectivity { return true }
            return false
        }
        let callsAfterFailure = await daemon.listCallCount

        // A structural SSE event arrives for the same (still-failed) host.
        await feed.receive(.hosted(host: .remote("work"), event: .agentSpawned(seq: 1, at: nil, agent: agent("bravo"))))
        for _ in 0..<50 { await Task.yield() }

        #expect(await daemon.listCallCount == callsAfterFailure, "SSE event for a failed host spuriously triggered a refresh")
        guard case .failed = await recorder.last?.connectivity else {
            Issue.record("Expected .failed connectivity to persist, got \(String(describing: await recorder.last?.connectivity))")
            return
        }

        await feed.stop()
    }

    private func agent(_ name: String) -> LeoAgent {
        .init(name: name, template: "default", repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
    }
}

private actor SnapshotRecorder {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    func append(_ snapshot: LeoSidebarSnapshot) { values.append(snapshot) }
}

private actor CountingDaemonClient: LeoDaemonClient {
    private(set) var listCallCount = 0

    func listAgents(host: LeoHostID) async throws -> [LeoAgent] {
        listCallCount += 1
        return []
    }

    func listAgents() async throws -> [LeoAgent] { fatalError() }
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
