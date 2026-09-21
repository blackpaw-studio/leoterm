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
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "LeoSidebarFeed")

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
    private let sleeper: @Sendable (UInt64) async throws -> Void
    var snapshot = LeoSidebarSnapshot(rows: [], connectivity: .loading, generation: 0)
    var activityByName: [String: LeoSidebarActivity] = [:]
    var bufferedActivity: [LeoObserveEvent] = []
    var eventTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var activityTask: Task<Void, Never>?
    private var emissionTask: Task<Void, Never>?
    var pollTask: Task<Void, Never>?
    var sseRefreshTask: Task<Void, Never>?
    var scheduler = LeoPollScheduler()
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
        onManualRefresh: @escaping @MainActor @Sendable () -> Void = {},
        sink: @escaping Sink
    ) {
        self.daemon = daemon
        activitySource = activity
        sleeper = sleep
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
        eventTask = nil
        refreshTask = nil
        activityTask = nil
        emissionTask = nil
        pollTask = nil
        sseRefreshTask = nil
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
        switch event {
        case .connected:
            guard !recovering else { return }
            awaitingHello = true
            prepareRecovery()
            // A pending coalesced-refresh sleep from just before the
            // reconnect must not fire a spurious refresh ~100ms later.
            sseRefreshTask?.cancel()
            sseRefreshTask = nil
            process(scheduler.reduce(.sseEvent(event)))
        case .hello:
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
            if recovering { bufferedActivity.append(event) } else { applyActivity(event) }
        case .disconnected:
            // A pending coalesced-refresh sleep is now moot -- the stream
            // that scheduled it is gone.
            sseRefreshTask?.cancel()
            sseRefreshTask = nil
            activityByName = [:]
            bufferedActivity = []
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
            recovering = false
            let buffered = bufferedActivity
            bufferedActivity = []
            buffered.forEach(applyActivity)
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

    private func fetchActivityState(generation: Int) {
        activityTask?.cancel()
        activityTask = Task { [weak self, activitySource] in
            do {
                let state = try await Self.fetchState(from: activitySource)
                guard let self else { return }
                await self.applyActivityState(state, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func fetchList() async throws -> [LeoAgent] {
        let daemon = daemon
        let sleeper = sleeper
        let race = LeoListFetchRace()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                let listTask = Task {
                    do {
                        race.finish(.success(try await daemon.listAgents()), winner: .list)
                    } catch {
                        race.finish(.failure(error), winner: .list)
                    }
                }
                let deadlineTask = Task {
                    do {
                        try await sleeper(5_000_000_000)
                        race.finish(.failure(LeoSidebarFeedError.listTimedOut), winner: .deadline)
                    } catch {
                        race.finish(.failure(error), winner: .deadline)
                    }
                }
                race.install(listTask: listTask, deadlineTask: deadlineTask)
            }
        } onCancel: {
            race.cancel()
        }
        return try result.get()
    }

    private func applyActivityState(_ state: [LeoObservedAgent], generation: Int) {
        guard running, generation == snapshot.generation else { return }
        activityByName = Self.activities(state)
        snapshot = LeoSidebarSnapshot(rows: LeoSidebarReducers.mergeActivity(snapshot.rows, activityByName: activityByName), connectivity: snapshot.connectivity, generation: generation)
        emit()
    }

    private static func fetchState(from source: LeoSidebarActivitySource) async throws -> [LeoObservedAgent] {
        try await withThrowingTaskGroup(of: [LeoObservedAgent].self) { group in
            group.addTask { try await source.fetchState() }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw LeoSidebarFeedError.activityStateTimedOut
            }
            defer { group.cancelAll() }
            guard let state = try await group.next() else { return [] }
            return state
        }
    }

    private func finishRefresh() {
        refreshTask = nil
        guard running else { return }
        process(scheduler.reduce(.refreshFinished))
    }

    private func applyActivity(_ event: LeoObserveEvent) {
        guard case let .agentActivity(_, _, name, activity, currentAction) = event else { return }
        let overlay = LeoSidebarActivity(activity: Self.activity(activity), detail: currentAction?.detail)
        activityByName[name] = overlay
        snapshot = LeoSidebarSnapshot(rows: LeoSidebarReducers.mergeActivity(snapshot.rows, activityByName: activityByName), connectivity: snapshot.connectivity, generation: snapshot.generation)
        emit()
    }

    func emit() {
        let value = snapshot
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

    /// No host filtering: `activitySource` is already scoped to exactly one
    /// connection (see `LeoSidebarFeedTarget.updateConnection`).
    private static func activities(_ agents: [LeoObservedAgent]) -> [String: LeoSidebarActivity] {
        Dictionary(agents.map {
            ($0.name, LeoSidebarActivity(activity: activity($0.activity), detail: $0.currentAction?.detail))
        }, uniquingKeysWith: { _, latest in latest })
    }

    private static func activity(_ activity: LeoActivity?) -> LeoAgentRow.Activity {
        switch activity {
        case .working: .working
        case .idle: .idle
        case .unknown, nil: .unknown
        }
    }
}

