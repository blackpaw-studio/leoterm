import Foundation
import OSLog

struct LeoSidebarActivitySource: Sendable {
    let events: @Sendable () async -> AsyncStream<LeoObserveEvent>
    let fetchState: @Sendable () async throws -> [LeoObservedAgent]

    init(events: @escaping @Sendable () async -> AsyncStream<LeoObserveEvent>, fetchState: @escaping @Sendable () async throws -> [LeoObservedAgent]) {
        self.events = events
        self.fetchState = fetchState
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
    var sseRefreshTask: Task<Void, Never>?
    var scheduler = LeoPollScheduler()
    /// Semantic attention for the selected host -- see `LeoSidebarFeed+Attention.swift`.
    var attention = LeoAttentionReducer()
    var attentionTask: Task<Void, Never>?
    /// Monotonic seconds; only the attention reducer's stability window reads it.
    let now: @Sendable () -> TimeInterval
    let onAttentionTransitions: @MainActor @Sendable ([LeoAttentionTransition]) -> Void
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
    var selectedHostAvailable = true
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
        eventTask = Task { [weak self, activitySource] in
            let events = await activitySource.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.receive(event)
            }
        }
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
        case .hello(let seq, _, let version, _):
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
            process(scheduler.reduce(.sseEvent(event)))
        case .agentActivity:
            if recovering {
                bufferedActivity.append(event)
            } else if activityCoalescer.add(event) {
                scheduleActivityFlush()
            }
        case .disconnected(let reason):
            Self.logger.log("receive: .disconnected reason=\(reason, privacy: .public)")
            // A pending coalesced-refresh sleep is now moot -- the stream
            // that scheduled it is gone.
            sseRefreshTask?.cancel()
            sseRefreshTask = nil
            activityByName = [:]
            bufferedActivity = []
            attention.disconnect()
            scheduleAttentionTick()
            snapshot = LeoSidebarSnapshot(
                rows: snapshot.rows.map {
                    LeoAgentRow(host: $0.host, name: $0.name, template: $0.template, status: $0.status, activity: .unknown, actionDetail: nil)
                },
                connectivity: snapshot.connectivity,
                generation: snapshot.generation
            )
            // Tells the scheduler SSE is down so it falls back to periodic
            // polling instead of staying paused forever (this was missing:
            // `.disconnected` never reached the scheduler before).
            process(scheduler.reduce(.sseEvent(event)))
            emit()
        }
    }

    private func prepareRecovery() {
        snapshot = LeoSidebarSnapshot(rows: snapshot.rows, connectivity: snapshot.connectivity, generation: snapshot.generation + 1)
        activityByName = [:]
        recovering = true
        needsState = true
        attention.beginRecovery()
        scheduleAttentionTick()
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
        do {
            let rows = try await fetchList().map { Self.row($0, host: host) }
            guard running, generation == snapshot.generation, token == currentRefreshToken else { return }
            snapshot = LeoSidebarReducers.applyListResult(snapshot, result: LeoSidebarReducers.mergeActivity(rows, activityByName: activityByName), generation: generation)
            retainAttention(for: rows)
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
            if fetchState { fetchActivityState(generation: generation) }
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            guard running, generation == snapshot.generation, token == currentRefreshToken else { return }
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
        let value = snapshot.overlayingAttention(attention)
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
        LeoAgentRow(host: host, name: agent.name, template: agent.template, status: agent.status ?? .unknown("missing"), activity: .unknown, actionDetail: nil, workspace: agent.workspace, repo: agent.repo)
    }
}

