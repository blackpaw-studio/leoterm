import Foundation
import Testing

@testable import Ghostty

/// `updateConnection(host:generation:phase:)` is the single chokepoint that
/// swaps which daemon/activity source a `LeoSidebarFeed` talks to. These
/// tests cover the three invariants that matter for a connection switch: a
/// stale emission from the connection being replaced must never reach the
/// new one; a `.failed` connection keeps its last-known rows (greyed, not
/// cleared); and after a switch, only the new connection's daemon ever sees
/// another request.
struct LeoSidebarFeedHostSwitchTests {
    /// Covers a refresh-ownership race: `performRefresh`'s cleanup ran
    /// unconditionally whenever the refresh wasn't itself cancelled. If a
    /// prior connection's underlying daemon call resolved with a real result
    /// just as (or just after) a switch cancelled it, the cancellation could
    /// lose that race, and the stale refresh's cleanup could clear
    /// bookkeeping that actually belonged to the newer, still in-flight
    /// refresh -- letting the scheduler believe nothing was in flight and
    /// permit a spurious duplicate refresh.
    @Test func staleRefreshFromPriorConnectionNeverClobbersNewConnectionOwnership() async throws {
        for _ in 0..<10 {
            try await runStaleRefreshTrial()
        }
    }

    private func runStaleRefreshTrial() async throws {
        let daemonA = LeoGatedListDaemon()
        let daemonB = LeoGatedListDaemon()
        let recorder = LeoSnapshotRecorder()
        let feed = LeoSidebarFeed(daemon: daemonA, activity: Self.emptyActivity) { snapshot in
            Task { await recorder.append(snapshot) }
        }

        await feed.start()
        await feed.setInitialPolling(true)
        await feed.updateConnection(host: .local, generation: 1, phase: .connected(daemon: daemonA, activitySource: Self.emptyActivity))
        await awaitCondition(message: "First refresh (A) was not requested") { await daemonA.callCount == 1 }

        // Switch connections first -- this synchronously cancels A's
        // in-flight refresh and starts B's -- and only then release A's
        // stale result. That forces the exact interleaving the invariant
        // must survive: a prior connection's completion arriving strictly
        // after the newer connection has already taken ownership.
        let switchIndex = await recorder.values.count
        await feed.updateConnection(host: .remote("work"), generation: 2, phase: .connected(daemon: daemonB, activitySource: Self.emptyActivity))
        await daemonA.resolve(index: 0, .success([Self.agent("alpha")]))

        await awaitCondition(message: "Second refresh (B) was not requested") { await daemonB.callCount >= 1 }
        for _ in 0..<50 { await Task.yield() }

        let callsBeforeExtraRequest = await daemonB.callCount
        await feed.refresh()
        for _ in 0..<50 { await Task.yield() }
        let callsAfterExtraRequest = await daemonB.callCount
        #expect(
            callsAfterExtraRequest == callsBeforeExtraRequest,
            "A's completion spuriously allowed a duplicate refresh (\(callsBeforeExtraRequest) -> \(callsAfterExtraRequest))"
        )

        await daemonB.resolveAllPending(.success([Self.agent("bravo")]))
        await awaitCondition(message: "The newer connection's result was not installed") {
            await recorder.last?.rows.map(\.name) == ["bravo"]
        }
        #expect(
            await recorder.values[switchIndex...].allSatisfy { $0.rows.map(\.name) != ["alpha"] },
            "Stale connection A data leaked into a published snapshot after the switch to connection B"
        )
        #expect(await daemonA.callCount == 1, "the superseded connection's daemon must never be called again")

        await feed.stop()
    }

    @Test func failedConnectionKeepsLastRowsGreyedInsteadOfClearingThem() async throws {
        let daemon = LeoStaticListDaemon(agents: [Self.agent("alpha")])
        let recorder = LeoSnapshotRecorder()
        let feed = LeoSidebarFeed(daemon: daemon, activity: Self.emptyActivity) { snapshot in
            Task { await recorder.append(snapshot) }
        }

        await feed.start()
        await feed.setInitialPolling(true)
        await feed.updateConnection(host: .remote("work"), generation: 1, phase: .connected(daemon: daemon, activitySource: Self.emptyActivity))
        await awaitCondition { await recorder.last?.rows.map(\.name) == ["alpha"] }

        // Same connection (host + generation) transitions to failed -- e.g.
        // the tunnel died. This is a phase update, not a switch.
        await feed.updateConnection(host: .remote("work"), generation: 1, phase: .failed(message: "ssh died"))

        await awaitCondition(message: "never reached .failed") {
            if case .failed(let message) = await recorder.last?.connectivity { return message == "ssh died" }
            return false
        }
        #expect(await recorder.last?.rows.map(\.name) == ["alpha"], "rows must stay (greyed via .failed connectivity), not clear")

        await feed.stop()
    }

    @Test func switchingToAFailedNewHostShowsNoStaleRowsFromThePreviousHost() async throws {
        let daemon = LeoStaticListDaemon(agents: [Self.agent("alpha")])
        let recorder = LeoSnapshotRecorder()
        let feed = LeoSidebarFeed(daemon: daemon, activity: Self.emptyActivity) { snapshot in
            Task { await recorder.append(snapshot) }
        }

        await feed.start()
        await feed.setInitialPolling(true)
        await feed.updateConnection(host: .local, generation: 1, phase: .connected(daemon: daemon, activitySource: Self.emptyActivity))
        await awaitCondition { await recorder.last?.rows.map(\.name) == ["alpha"] }

        // A genuinely NEW host+generation failing immediately (e.g. an
        // unconfigured remote host) is a switch: it must never show the
        // previous host's rows.
        await feed.updateConnection(host: .remote("ghost"), generation: 2, phase: .failed(message: "Unknown host ghost"))

        await awaitCondition(message: "never reached .failed") {
            if case .failed = await recorder.last?.connectivity { return true }
            return false
        }
        #expect(await recorder.last?.rows.isEmpty == true)

        await feed.stop()
    }

    @Test func connectionSnapshotDeterminesWhichDaemonReceivesRequests() async throws {
        let daemonA = LeoStaticListDaemon(agents: [Self.agent("a")])
        let daemonB = LeoStaticListDaemon(agents: [Self.agent("b")])
        let recorder = LeoSnapshotRecorder()
        let feed = LeoSidebarFeed(daemon: daemonA, activity: Self.emptyActivity) { snapshot in
            Task { await recorder.append(snapshot) }
        }

        await feed.start()
        await feed.setInitialPolling(true)
        await feed.updateConnection(host: .local, generation: 1, phase: .connected(daemon: daemonA, activitySource: Self.emptyActivity))
        await awaitCondition { await recorder.last?.rows.map(\.name) == ["a"] }

        await feed.updateConnection(host: .remote("work"), generation: 2, phase: .connected(daemon: daemonB, activitySource: Self.emptyActivity))
        await awaitCondition { await recorder.last?.rows.map(\.name) == ["b"] }

        let callsToAAtSwitch = await daemonA.callCount
        await feed.refresh()
        for _ in 0..<20 { await Task.yield() }
        #expect(await daemonA.callCount == callsToAAtSwitch, "the superseded connection's daemon must never receive another request")
        #expect(await daemonB.callCount >= 1)

        await feed.stop()
    }

    /// A poll tick landing while `.connecting` used to return (via the
    /// `selectedHostAvailable` guard in `tick()`) WITHOUT rescheduling
    /// `pollTask` -- so once reconnected, periodic polling stayed dead
    /// forever even with unchanged visibility. Verifies the scheduler is
    /// explicitly paused on `.connecting` and explicitly resumed
    /// (rescheduling the next tick) on `.connected`.
    @Test func pollingResumesAfterConnectingRatherThanStayingDeadForever() async throws {
        let clock = LeoGatedSleepClock()
        let daemon = LeoStaticListDaemon(agents: [Self.agent("a")])
        let recorder = LeoSnapshotRecorder()
        let feed = LeoSidebarFeed(
            daemon: daemon, activity: Self.emptyActivity, sleep: { try await clock.sleep($0) },
            sink: { snapshot in Task { await recorder.append(snapshot) } }
        )

        await feed.start()
        await feed.setInitialPolling(true)
        await feed.updateConnection(host: .remote("work"), generation: 1, phase: .connected(daemon: daemon, activitySource: Self.emptyActivity))

        // Establish that polling is genuinely active BEFORE the reconnect:
        // the initial refresh happened, a tick was scheduled, and advancing
        // the clock actually fires it.
        await awaitCondition(message: "initial refresh never happened") { await daemon.callCount >= 1 }
        await awaitCondition(message: "poll tick was never scheduled") { await clock.waiterCount >= 1 }
        await clock.advance()
        await awaitCondition(message: "the established tick never refreshed") { await daemon.callCount >= 2 }
        await awaitCondition(message: "poll tick was never rescheduled") { await clock.waiterCount >= 1 }

        // The tunnel drops and LeoHostSelection retries: a NEW generation
        // goes through `.connecting` (pausing the scheduler) before
        // `.connected` again -- exactly the transition that used to leave
        // polling permanently dead.
        let callsBeforeReconnect = await daemon.callCount
        await feed.updateConnection(host: .remote("work"), generation: 2, phase: .connecting)
        await feed.updateConnection(host: .remote("work"), generation: 2, phase: .connected(daemon: daemon, activitySource: Self.emptyActivity))

        await awaitCondition(message: "the reconnect's own refresh never happened") { await daemon.callCount > callsBeforeReconnect }
        await awaitCondition(message: "poll tick was never rescheduled after reconnecting") { await clock.waiterCount >= 1 }

        await clock.advance()
        await awaitCondition(message: "first post-reconnect tick never refreshed") { await daemon.callCount > callsBeforeReconnect + 1 }
        await awaitCondition(message: "poll tick was never rescheduled again") { await clock.waiterCount >= 1 }

        await clock.advance()
        await awaitCondition(message: "second post-reconnect tick never refreshed") { await daemon.callCount > callsBeforeReconnect + 2 }

        await feed.stop()
    }

    /// A connection switch used to leave the scheduler's SSE-connectivity
    /// tracking (`sseConnected`/`pendingSSERefresh`) stuck at whatever the
    /// superseded connection last reported, and never cancelled its pending
    /// coalesced-refresh task. If the old connection's SSE was connected when
    /// the switch happened, the new connection's `sidebarVisibleCountChanged`
    /// computed `shouldPoll == false` from that stale state, so the 30s
    /// fallback poll never started for it -- it stayed dead until the new
    /// connection's own SSE happened to report `.connected`/`.disconnected`.
    @Test func switchingConnectionsCancelsAPendingCoalescedSSERefreshAndStartsFallbackPollingForTheNewConnection() async throws {
        let clock = LeoGatedSleepClock()
        let daemonA = LeoStaticListDaemon(agents: [Self.agent("a")])
        let daemonB = LeoStaticListDaemon(agents: [Self.agent("b")])
        let activityA = LeoEventActivitySource()
        let recorder = LeoSnapshotRecorder()
        // The constructor is wired to an inert placeholder, not `activityA`
        // -- `AsyncStream` has no fan-out, so registering the same live
        // stream with two consumers (the constructor's initial `eventTask`
        // AND the one `updateConnection` starts below) would race them for
        // events. Only `updateConnection`'s `.connected` phase below ever
        // wires `activityA` in, matching how a real connection is
        // established (see `pollingResumesAfterConnectingRatherThanStayingDeadForever`).
        let feed = LeoSidebarFeed(
            daemon: daemonA,
            activity: Self.emptyActivity,
            sleep: { try await clock.sleep($0) },
            sink: { snapshot in Task { await recorder.append(snapshot) } }
        )

        await feed.start()
        await feed.setInitialPolling(true)
        await feed.updateConnection(
            host: .local, generation: 1,
            phase: .connected(daemon: daemonA, activitySource: .init(events: { await activityA.events() }, fetchState: { await activityA.fetchState() }))
        )
        await awaitCondition(message: "initial refresh for A never happened") { await daemonA.callCount >= 1 }

        // SSE actually connects for A: the fallback poll pauses in favor of
        // push-driven refreshes.
        await activityA.send(.connected)
        await awaitCondition(message: "the SSE-connect refresh for A never happened") { await daemonA.callCount >= 2 }

        // A structural event arrives and schedules a coalesced refresh that
        // has NOT fired yet when the connection switches away from A.
        await activityA.send(.agentStopped(seq: 1, at: nil, agent: "a", wakeOnMessage: nil))
        await awaitCondition(message: "the coalesced SSE refresh was never scheduled") { await clock.waiterCount >= 1 }

        await feed.updateConnection(host: .remote("work"), generation: 2, phase: .connected(daemon: daemonB, activitySource: Self.emptyActivity))
        await awaitCondition(message: "the new connection never refreshed") { await daemonB.callCount >= 1 }

        // B's own SSE hasn't connected yet -- the scheduler must keep
        // re-polling it on the 30s fallback cadence rather than sitting dead
        // because of A's now-irrelevant, stale SSE-connected state.
        let callsAfterSwitch = await daemonB.callCount
        for _ in 0..<3 {
            await awaitCondition(message: "fallback poll tick was never (re)scheduled for the new connection") { await clock.waiterCount >= 1 }
            await clock.advance()
        }
        await awaitCondition(message: "fallback polling never kept refreshing the new connection") { await daemonB.callCount > callsAfterSwitch }

        await feed.stop()
    }

    private static let emptyActivity = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })

    private static func agent(_ name: String) -> LeoAgent {
        .init(name: name, template: "default", repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)
    }
}

/// A controllable stand-in for `LeoSidebarFeed`'s injectable `sleep`, used
/// here to gate the poll scheduler's `.scheduleTick` waits so a test can
/// deterministically fire exactly one "tick" at a time.
private actor LeoGatedSleepClock {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var waiterCount: Int { waiters.count }

    /// `fetchList()`'s own 5s deadline race ALSO uses the feed's injected
    /// `sleeper` -- so this must be cancellation-aware (removing its
    /// continuation the instant that deadline task is cancelled, e.g.
    /// because the list call itself already won the race) or a cancelled
    /// deadline task's parked continuation would leak forever, silently
    /// inflating `waiterCount` with stale entries `advance()` could
    /// mistakenly resume instead of the real scheduled tick.
    func sleep(_ nanoseconds: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { waiters[id] = $0 }
            },
            onCancel: { Task { await self.cancelWaiter(id) } }
        )
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func advance() {
        guard let (id, continuation) = waiters.first else { return }
        waiters.removeValue(forKey: id)
        continuation.resume()
    }
}

/// An activity source whose SSE events are sent on demand, so a test can
/// deliver a specific event (e.g. a structural change that schedules a
/// coalesced refresh) at a precise moment relative to a connection switch.
private actor LeoEventActivitySource {
    private let stream: AsyncStream<LeoObserveEvent>
    private let continuation: AsyncStream<LeoObserveEvent>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream() }
    func events() -> AsyncStream<LeoObserveEvent> { stream }
    func fetchState() -> [LeoObservedAgent] { [] }
    func send(_ event: LeoObserveEvent) { continuation.yield(event) }
}

private actor LeoSnapshotRecorder {
    private(set) var values: [LeoSidebarSnapshot] = []
    var last: LeoSidebarSnapshot? { values.last }
    func append(_ snapshot: LeoSidebarSnapshot) { values.append(snapshot) }
}

/// Always returns the same fixed list immediately.
private actor LeoStaticListDaemon: LeoDaemonClient {
    private let agents: [LeoAgent]
    private(set) var callCount = 0

    init(agents: [LeoAgent]) { self.agents = agents }

    func listAgents() async throws -> [LeoAgent] {
        callCount += 1
        return agents
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

/// A daemon fake whose `listAgents()` calls are individually resolvable and
/// do not cooperate with `Task` cancellation (matching how a real in-flight
/// socket read can't be aborted mid-flight), so a test can force the exact
/// "cancellation races a real result" interleaving that production code
/// must tolerate.
private actor LeoGatedListDaemon: LeoDaemonClient {
    private var waiters: [(id: Int, continuation: CheckedContinuation<Result<[LeoAgent], Error>, Never>)] = []
    private var nextID = 0
    private(set) var callCount = 0

    func listAgents() async throws -> [LeoAgent] {
        callCount += 1
        let id = nextID
        nextID += 1
        return try await withCheckedContinuation { waiters.append((id, $0)) }.get()
    }

    /// Resolves the Nth call to `listAgents()` (0-indexed by call order).
    func resolve(index: Int, _ result: Result<[LeoAgent], Error>) {
        guard let position = waiters.firstIndex(where: { $0.id == index }) else { return }
        waiters.remove(at: position).continuation.resume(returning: result)
    }

    func resolveAllPending(_ result: Result<[LeoAgent], Error>) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(returning: result) }
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
