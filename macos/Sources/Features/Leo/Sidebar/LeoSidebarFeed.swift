import Foundation
import OSLog

struct LeoSidebarActivitySource: Sendable {
    let events: @Sendable () async -> AsyncStream<LeoObserveEvent>
    let fetchState: @Sendable () async throws -> LeoObservedState

    init(events: @escaping @Sendable () async -> AsyncStream<LeoObserveEvent>, observedState: @escaping @Sendable () async throws -> LeoObservedState) {
        self.events = events
        fetchState = observedState
    }

    /// For a source that only knows agents (no dispatches).
    init(events: @escaping @Sendable () async -> AsyncStream<LeoObserveEvent>, fetchState: @escaping @Sendable () async throws -> [LeoObservedAgent]) {
        self.init(events: events, observedState: { LeoObservedState(agents: try await fetchState()) })
    }

    init(client: LeoActivityClient) {
        events = { await client.events() }
        fetchState = { try await client.fetchState() }
    }
}

/// Reads agent activity/list data for exactly one connection at a time --
/// `daemon`/`activitySource` are swapped via `updateConnection(host:generation:phase:)`
/// (see `LeoSidebarFeedTarget.swift`) whenever `LeoHostSelection` reports a
/// new `(host, generation)`. Every async chokepoint (refresh, activity-state
/// fetch, SSE consumption) is guarded by `snapshot.generation` and/or
/// `connectionGeneration` so a stale emission from a superseded connection
/// can never reach a newer one.
actor LeoSidebarFeed {
    typealias Sink = @MainActor @Sendable (LeoSidebarSnapshot) -> Void
    static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "LeoSidebarFeed")

    var daemon: any LeoDaemonClient
    var activitySource: LeoSidebarActivitySource
    private let sink: Sink
    /// Fired only when a refresh that satisfies a `refresh()` (manual,
    /// `.refreshRequested`) call -- never a `.tick` (periodic poll) or
    /// `.sseEvent` (SSE-triggered) one -- successfully applies a fresh
    /// agent-list result. `LeoRuntime` uses this to invalidate the
    /// template cache: templates are host configuration, not agent state,
    /// so they must not be refetched on every (now SSE-driven, frequent)
    /// list refresh, only when the user explicitly asks the sidebar to
    /// refresh.
    private let onManualRefresh: @MainActor @Sendable () -> Void
    /// True while a still-pending refresh cycle needs to satisfy at least
    /// one `refresh()` call -- consumed (and reset) by `startRefresh()`
    /// when that cycle actually begins. Coalesced the same way the
    /// scheduler itself coalesces overlapping refresh requests: a manual
    /// request that arrives while a refresh is already in flight is
    /// satisfied by the very next refresh to start, whatever else also
    /// triggered it.
    private var manualRefreshPending = false
    let sleeper: @Sendable (UInt64) async throws -> Void
    var snapshot = LeoSidebarSnapshot(rows: [], connectivity: .loading, generation: 0)
    var activityByName: [String: LeoSidebarActivity] = [:]
    /// Row metadata from the latest applied `/state` snapshot -- see
    /// `LeoSidebarFeed+Metadata.swift`.
    var metadata = LeoAgentMetadataIndex.empty
    var metadataTask: Task<Void, Never>?
    /// The request number of the metadata fetch in flight, if any.
    var metadataInFlight: Int?
    /// A snapshot is owed: asked for while one was in flight, or activity
    /// was drained outside a flush. Consumed when the fetch in flight
    /// finishes, after a list refresh, and after a `/state` baseline
    /// applies; cleared by `resetMetadata` and when a baseline fetch
    /// starts (the baseline covers it).
    var metadataRefreshPending = false
    var metadataRequestSeq = 0
    var metadataAppliedSeq = 0
    var bufferedActivity: [LeoObserveEvent] = []
    /// Coalesces `agentActivity` SSE events so a chatty agent applies at
    /// most one merge + emission per `activityCoalesceInterval`, instead of
    /// one per event -- see `LeoActivityCoalescer`.
    var activityCoalescer = LeoActivityCoalescer()
    var activityCoalesceTask: Task<Void, Never>?
    /// Coalescing window for bursts of `agentActivity` events -- mirrors
    /// `LeoPollScheduler.sseCoalesceInterval`'s pattern of a named constant
    /// plus the injected `sleeper`.
    static let activityCoalesceInterval: TimeInterval = 0.1
    var eventTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var activityTask: Task<Void, Never>?
    private var emissionTask: Task<Void, Never>?
    var pollTask: Task<Void, Never>?
    /// The one wake liveness check in flight, if any (see `checkLiveness`).
    var livenessTask: Task<Void, Never>?
    /// Identifies the latest wake check; an older one's result is stale.
    var livenessToken = 0
    var sseRefreshTask: Task<Void, Never>?
    var scheduler = LeoPollScheduler()
    /// Semantic attention for the selected host -- see `LeoSidebarFeed+Attention.swift`.
    var attention = LeoAttentionReducer()
    var attentionTask: Task<Void, Never>?
    /// Monotonic seconds; only the attention reducer's stability window reads it.
    let now: @Sendable () -> TimeInterval
    let onAttentionTransitions: @MainActor @Sendable ([LeoAttentionTransition]) -> Void
    /// Files surfaced on the selected host (B-013), by incarnation.
    var surfacedFiles = LeoSurfacedFileIndex.empty
    /// The selected host's live dispatches (B-257) -- see `LeoSidebarFeed+Dispatches.swift`.
    var dispatchTree = LeoDispatchTree()
    /// What the selected host's daemon advertised on its latest hello, and
    /// the last-turn previews it gated (B-259) -- see `LeoSidebarFeed+Turns.swift`.
    var daemonFeatures = LeoDaemonFeatures.none
    var turnPreviews = LeoTurnPreviews.empty
    /// Agents compacting now (B-261) -- see `LeoSidebarFeed+Compaction.swift`.
    var compactions = LeoCompactions.empty
    var running = false
    var needsState = true
    var recovering = false
    var awaitingHello = false
    var selectedHost: LeoHostID = .local
    /// The `(host, generation)` this feed is currently wired to -- identifies
    /// a *connection*, distinct from `selectedHost` alone, so a retry of the
    /// same host (a new generation) is still recognized as a switch.
    var connectionHost: LeoHostID = .local
    var connectionGeneration = 0
    /// How far the current connection's phases have got (see
    /// `LeoSidebarConnectionPhase.order`): within one generation they only
    /// move forward, so a late earlier phase is stale.
    var connectionPhaseOrder = 0
    var selectedHostAvailable = true
    /// A list has landed for this host since the user last switched to
    /// it: a later failure is a *drop* (disconnected, rows kept), not a
    /// connect failure. Survives a same-host Retry.
    var wasLive = false
    var pollingRequested = false
    /// Bumped each time a refresh starts; lets a stale refresh whose
    /// cancellation lost a race recognize it no longer owns bookkeeping.
    private var currentRefreshToken = 0

    init(
        daemon: any LeoDaemonClient, activity: LeoSidebarActivitySource,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onManualRefresh: @escaping @MainActor @Sendable () -> Void = {},
        onAttentionTransitions: @escaping @MainActor @Sendable ([LeoAttentionTransition]) -> Void = { _ in },
        sink: @escaping Sink
    ) {
        self.daemon = daemon
        activitySource = activity
        sleeper = sleep
        self.now = now
        self.onAttentionTransitions = onAttentionTransitions
        self.onManualRefresh = onManualRefresh
        self.sink = sink
    }

    func start() {
        guard !running else { return }
        running = true
        startEventTask()
    }

    func stop() {
        running = false
        eventTask?.cancel()
        refreshTask?.cancel()
        activityTask?.cancel()
        emissionTask?.cancel()
        pollTask?.cancel()
        sseRefreshTask?.cancel()
        activityCoalesceTask?.cancel()
        attentionTask?.cancel()
        cancelLivenessCheck()
        resetMetadata()
        resetDispatches()
        resetTurns()
        resetCompactions()
        attentionTask = nil
        eventTask = nil
        refreshTask = nil
        activityTask = nil
        emissionTask = nil
        pollTask = nil
        sseRefreshTask = nil
        activityCoalesceTask = nil
        activityCoalescer = LeoActivityCoalescer()
        scheduler.reset()
    }

    func startEventTask() {
        eventTask?.cancel()
        guard running else { return }
        eventTask = Task { [weak self, activitySource, connectionGeneration] in
            let events = await activitySource.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.receive(event, generation: connectionGeneration)
            }
        }
    }

    /// An event from the stream of connection `generation`. One dequeued
    /// just before a switch can still land after it; it's dropped so it
    /// can't invent a state or plant another host's boot id.
    func receive(_ event: LeoObserveEvent, generation: Int) {
        guard generation == connectionGeneration else { return }
        receive(event)
    }

    func refresh() {
        guard running, selectedHostAvailable else { return }
        manualRefreshPending = true
        process(scheduler.reduce(.refreshRequested))
    }

    func tick() {
        guard running, selectedHostAvailable else { return }
        process(scheduler.reduce(.tick))
    }

    private func sseRefreshDue() {
        guard running, selectedHostAvailable else { return }
        process(scheduler.reduce(.sseRefreshDue))
    }

    func setPolling(_ pollable: Bool) {
        guard running else { return }
        pollingRequested = pollable
        // Connecting, failed or disconnected: only recorded. `.connected`
        // (see `updateConnection`) starts polling from it; no timer may run
        // against an unavailable host.
        guard selectedHostAvailable else { return }
        process(scheduler.reduce(.sidebarVisibleCountChanged(pollable ? 1 : 0)))
    }

    /// Sets the initial polling-requested flag without triggering a
    /// scheduler transition -- used exactly once at startup, before the
    /// first connection has been established, so the connection's own
    /// `.connected` phase (see `updateConnection`) owns the single "start
    /// polling" transition instead of racing it. Later visibility changes
    /// go through `setPolling(_:)`, which does trigger the transition.
    func setInitialPolling(_ pollable: Bool) {
        guard running else { return }
        pollingRequested = pollable
    }

    func receive(_ event: LeoObserveEvent) {
        guard running else { return }
        // Sequence-only and dispatch events never touch the activity
        // coalescer or the attention reducer: a turn event or a dispatch
        // tick must not flush the window early.
        switch event {
        case .other: return
        case .dispatchChanged(_, let dispatch):
            receiveDispatch(dispatch)
            return
        case .agentTurnCompleted(_, let turn):
            // A finished turn means the compaction (if any) is over.
            endCompaction(turn.agent)
            receiveTurn(turn)
            return
        case .agentCompaction(_, let compaction):
            receiveCompaction(compaction)
            return
        case .agentUsage:
            receiveUsageEvent()
            return
        case .hello(_, _, _, _, let bootID, let features):
            receiveFeatures(bootID: bootID, features: features)
            observeCompactionBoot(bootID)
            receiveDispatchHello(bootID: bootID, features: features)
        default: break
        }
        // Every non-activity event either emits directly (`.disconnected`)
        // or triggers a refresh that will (lifecycle/recovery events, via
        // `performRefresh`/`applyActivityState`) -- flush whatever's
        // buffered first so that emission reflects the latest activity
        // instead of a still-pending coalescing window.
        if case .agentActivity = event {} else { drainCoalescedActivity() }
        receiveAttention(event)
        switch event {
        case .connected:
            Self.logger.log("receive: .connected")
            guard !recovering else { return }
            awaitingHello = true
            prepareRecovery()
            // A pending coalesced-refresh sleep from just before the
            // reconnect must not fire a spurious refresh ~100ms later.
            sseRefreshTask?.cancel()
            sseRefreshTask = nil
            process(scheduler.reduce(.sseEvent(event)))
        case .hello(let seq, _, let version, _, _, _):
            Self.logger.log("receive: .hello seq=\(seq) version=\(version ?? "nil", privacy: .public) awaitingHello=\(self.awaitingHello)")
            if awaitingHello {
                awaitingHello = false
                return
            }
            guard !recovering else { return }
            prepareRecovery()
            process(scheduler.reduce(.sseEvent(event)))
        case .gap, .snapshot:
            guard !recovering else { return }
            prepareRecovery()
            process(scheduler.reduce(.sseEvent(event)))
        case .agentSpawned, .agentStateChanged, .agentStopped:
            if case .agentSpawned(_, _, let agent, _) = event { forgetTurn(agent.name); endCompaction(agent.name) }
            if case .agentStopped(_, _, let name, _) = event { forgetTurn(name); endCompaction(name) }
            process(scheduler.reduce(.sseEvent(event)))
            requestMetadataRefresh()
        case .agentActivity:
            if recovering {
                bufferedActivity.append(event)
            } else if activityCoalescer.add(event) {
                scheduleActivityFlush()
            }
        case .fileSurfaced(_, let file):
            receiveSurfacedFile(file)
        case .other, .dispatchChanged, .agentTurnCompleted, .agentUsage, .agentCompaction:
            return
        case .disconnected(let reason):
            Self.logger.log("receive: .disconnected reason=\(reason, privacy: .public)")
            // The stream is gone and nothing reconnects it but Retry (D-061).
            disconnect(reason: reason)
        }
    }

    private func prepareRecovery() {
        snapshot = LeoSidebarSnapshot(rows: snapshot.rows, connectivity: snapshot.connectivity, generation: snapshot.generation + 1)
        activityByName = [:]
        resetMetadata()
        resetCompactions()
        recovering = true
        needsState = true
        attention.beginRecovery()
        scheduleAttentionTick()
        syncBaselinePending()
    }

    func startRefresh() {
        _ = scheduler.reduce(.refreshStarted)
        let generation = snapshot.generation
        let host = selectedHost
        currentRefreshToken += 1
        let token = currentRefreshToken
        let isManual = manualRefreshPending
        manualRefreshPending = false
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(host: host, generation: generation, token: token, isManual: isManual)
        }
    }

    private func performRefresh(host: LeoHostID, generation: Int, token: Int, isManual: Bool) async {
        var wasCancelled = false
        // A stale refresh must not clear bookkeeping a newer one now owns.
        defer { if !wasCancelled, token == currentRefreshToken { finishRefresh() } }
        let fetchState = needsState
        needsState = false
        // Until the state fetch actually starts, a failed, stale or cancelled
        // list refresh leaves the baseline pending for the next poll --
        // otherwise the attention reducer would stay recovering for good.
        var stateFetchStarted = false
        defer { if fetchState, !stateFetchStarted { needsState = true } }
        let membershipMark = attention.membershipMark
        do {
            let rows = try await fetchList().map { Self.row($0, host: host) }
            guard running, generation == snapshot.generation, token == currentRefreshToken else { return }
            snapshot = LeoSidebarReducers.applyListResult(snapshot, result: LeoSidebarReducers.mergeActivity(rows, activityByName: activityByName), generation: generation)
            wasLive = true
            retainAttention(for: rows, listedSince: membershipMark)
            recovering = false
            drainCoalescedActivity()
            let buffered = bufferedActivity
            bufferedActivity = []
            mergeIntoActivityByName(buffered)
            // Still the same successful list refresh as `applyListResult`
            // above -- merging in buffered/coalesced activity must not
            // reset `listRefreshSucceeded` back to its `false` default.
            snapshot = snapshot.replacingRows(LeoSidebarReducers.mergeActivity(snapshot.rows, activityByName: activityByName), listRefreshSucceeded: true)
            emit()
            if isManual { await onManualRefresh() }
            if fetchState {
                stateFetchStarted = true
                fetchActivityState(generation: generation)
            } else if metadataRefreshPending {
                requestMetadataRefresh()
            }
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            guard running, generation == snapshot.generation, token == currentRefreshToken else { return }
            // A Retry whose list fails keeps the banner, with this reason.
            guard !isDisconnected else {
                disconnect(reason: error.localizedDescription)
                return
            }
            snapshot = LeoSidebarSnapshot(rows: snapshot.rows, connectivity: .failed(message: error.localizedDescription), generation: generation)
            emit()
        }
    }

    private func finishRefresh() {
        refreshTask = nil
        guard running else { return }
        process(scheduler.reduce(.refreshFinished))
    }

    func emit() {
        let value = displayedSnapshot.overlayingAttention(attention).overlayingDispatches(dispatchTree)
            .overlayingTurns(turnPreviews, features: daemonFeatures).overlayingCompactions(compactions)
            .advertising(daemonFeatures)
        let previous = emissionTask
        emissionTask = Task { [weak self, sink] in
            await previous?.value
            guard !Task.isCancelled, self != nil else { return }
            await sink(value)
        }
    }

    func process(_ outputs: [LeoPollScheduler.Output]) {
        for output in outputs {
            switch output {
            case .refreshNow:
                // Single chokepoint for every refresh trigger (poll, manual
                // refresh, retry, SSE): none may run against an unavailable host.
                guard running, selectedHostAvailable else { continue }
                startRefresh()
            case .scheduleTick(let interval):
                pollTask?.cancel()
                pollTask = Task { [weak self, sleeper] in
                    do {
                        try await sleeper(UInt64(interval * 1_000_000_000))
                    } catch is CancellationError {
                        return
                    } catch {
                        Self.logger.error("Leo sidebar polling sleep failed: \(String(describing: error), privacy: .public)")
                        return
                    }
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    await self.tick()
                }
            case .scheduleSSERefresh(let interval):
                sseRefreshTask?.cancel()
                sseRefreshTask = Task { [weak self, sleeper] in
                    do {
                        try await sleeper(UInt64(interval * 1_000_000_000))
                    } catch is CancellationError {
                        return
                    } catch {
                        Self.logger.error("Leo sidebar SSE-coalescing sleep failed: \(String(describing: error), privacy: .public)")
                        return
                    }
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    await self.sseRefreshDue()
                }
            case .pause:
                pollTask?.cancel()
                pollTask = nil
            case .resume:
                break
            }
        }
    }

    private static func row(_ agent: LeoAgent, host: LeoHostID) -> LeoAgentRow {
        LeoAgentRow(host: host, name: agent.name, template: agent.template, status: agent.status ?? .unknown("missing"), activity: .unknown, actionDetail: nil, workspace: agent.workspace, repo: agent.repo,
                    startedAt: agent.startedAt, wakeOnMessage: agent.wakeOnMessage)
    }
}

