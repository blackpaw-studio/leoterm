import Foundation
import Testing

@testable import Ghostty

/// Covers a refresh-ownership race: `performRefresh`'s `defer` cleanup ran
/// unconditionally whenever the refresh wasn't itself cancelled. If an older
/// (pre-host-switch) refresh's underlying daemon call happened to resolve
/// with a real result just as (or just after) the host switch cancelled it,
/// the cancellation could lose that race, the stale refresh would see a
/// generation mismatch and bail out *without* being marked cancelled, and its
/// `defer` would then clear bookkeeping that actually belonged to the newer,
/// still in-flight refresh for the newly selected host -- letting the
/// scheduler believe nothing was in flight and permit a spurious duplicate
/// refresh.
///
/// The exact interleaving is a genuine concurrency race (which underlying
/// call "wins"), so this exercises it many times: after the fix, the
/// invariant (no spurious duplicate refresh, and the newer host's result is
/// what's ultimately installed) must hold on every trial regardless of how
/// the race resolves.
struct LeoSidebarFeedHostSwitchTests {
    @Test func lateRefreshFromPriorHostNeverClobbersNewHostOwnership() async throws {
        for _ in 0..<25 {
            try await runTrial()
        }
    }

    private func runTrial() async throws {
        let daemon = FakeHostAwareDaemonClient()
        let recorder = SnapshotRecorder()
        let feed = LeoSidebarFeed(
            daemon: daemon,
            activity: .init(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        ) { snapshot in
            Task { await recorder.append(snapshot) }
        }

        await feed.start()
        await feed.setPolling(true)

        // Refresh A starts against the local host and hangs (unresolved).
        await awaitCondition(message: "First refresh (A) was not requested") { await daemon.listCallCount == 1 }

        // Race A's completion against the host switch that cancels it and
        // starts refresh B. Whichever wins, the outcome must be safe.
        async let resolveA: Void = daemon.resolve(index: 0, .success([agent("alpha")]))
        async let selectHost: Void = feed.select(.remote("work"))
        _ = await (resolveA, selectHost)

        await awaitCondition(message: "Second refresh (B) was not requested") { await daemon.listCallCount >= 2 }
        for _ in 0..<50 { await Task.yield() }

        // If A's cleanup wrongly cleared B's (or a still-pending refresh's)
        // in-flight bookkeeping, a fresh refresh request here would fire a
        // spurious extra request instead of being queued behind the one
        // already running.
        let callsBeforeExtraRequest = await daemon.listCallCount
        await feed.refresh()
        for _ in 0..<50 { await Task.yield() }
        let callsAfterExtraRequest = await daemon.listCallCount
        #expect(
            callsAfterExtraRequest == callsBeforeExtraRequest,
            "A's completion spuriously allowed a duplicate refresh (\(callsBeforeExtraRequest) -> \(callsAfterExtraRequest))"
        )

        // Whatever refresh is still outstanding resolves normally, and its
        // result -- not A's stale data -- is what ends up installed.
        await daemon.resolveAllPending(.success([agent("bravo")]))
        await awaitCondition(message: "The newer host's result was not installed") {
            await recorder.last?.rows.map(\.name) == ["bravo"]
        }
        #expect(await recorder.values.allSatisfy { $0.rows.map(\.name) != ["alpha"] }, "Stale host A data leaked into a published snapshot")

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

/// A daemon fake whose `listAgents(host:)` calls are individually resolvable
/// and do not cooperate with `Task` cancellation (matching how a real
/// in-flight socket read can't be aborted mid-flight), so a test can force
/// the exact "cancellation races a real result" interleaving that production
/// code must tolerate.
private actor FakeHostAwareDaemonClient: LeoDaemonClient {
    private var waiters: [(id: Int, continuation: CheckedContinuation<Result<[LeoAgent], Error>, Never>)] = []
    private var nextID = 0
    private(set) var listCallCount = 0

    func listAgents(host: LeoHostID) async throws -> [LeoAgent] {
        listCallCount += 1
        let id = nextID
        nextID += 1
        return try await withCheckedContinuation { waiters.append((id, $0)) }.get()
    }

    /// Resolves the Nth call to `listAgents(host:)` (0-indexed by call order).
    func resolve(index: Int, _ result: Result<[LeoAgent], Error>) {
        guard let position = waiters.firstIndex(where: { $0.id == index }) else { return }
        waiters.remove(at: position).continuation.resume(returning: result)
    }

    func resolveAllPending(_ result: Result<[LeoAgent], Error>) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(returning: result) }
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
