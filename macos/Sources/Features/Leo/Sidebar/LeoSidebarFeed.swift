import Foundation

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

actor LeoSidebarFeed {
    typealias Sink = @MainActor @Sendable (LeoSidebarSnapshot) -> Void

    private let daemon: any LeoDaemonClient
    private let activitySource: LeoSidebarActivitySource
    private let sink: Sink
    private var snapshot = LeoSidebarSnapshot(rows: [], connectivity: .loading, generation: 0)
    private var activityByName: [String: LeoSidebarActivity] = [:]
    private var bufferedActivity: [LeoObserveEvent] = []
    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var scheduler = LeoPollScheduler()
    private var running = false
    private var needsState = true
    private var recovering = false

    init(daemon: any LeoDaemonClient, activity: LeoSidebarActivitySource, sink: @escaping Sink) {
        self.daemon = daemon
        activitySource = activity
        self.sink = sink
    }

    func start() {
        guard !running else { return }
        running = true
        eventTask = Task { [activitySource] in
            let events = await activitySource.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self.receive(event)
            }
        }
    }

    func stop() {
        running = false
        eventTask?.cancel()
        refreshTask?.cancel()
        activityTask?.cancel()
        pollTask?.cancel()
        eventTask = nil
        refreshTask = nil
        activityTask = nil
        pollTask = nil
    }

    func refresh() { process(scheduler.reduce(.refreshRequested)) }

    func tick() { process(scheduler.reduce(.tick)) }

    func setPolling(_ pollable: Bool) {
        guard running else { return }
        process(scheduler.reduce(.sidebarVisibleCountChanged(pollable ? 1 : 0)))
    }

    func receive(_ event: LeoObserveEvent) {
        guard running else { return }
        switch event {
        case .connected, .hello, .gap, .snapshot:
            prepareRecovery()
            process(scheduler.reduce(.sseEvent(event)))
        case .agentSpawned, .agentStateChanged, .agentStopped:
            process(scheduler.reduce(.sseEvent(event)))
        case .agentActivity:
            if recovering { bufferedActivity.append(event) } else { applyActivity(event) }
        case .disconnected:
            activityByName = [:]
            bufferedActivity = []
            snapshot = LeoSidebarSnapshot(
                rows: snapshot.rows.map {
                    LeoAgentRow(host: $0.host, name: $0.name, template: $0.template, status: $0.status, activity: .unknown, actionDetail: nil)
                },
                connectivity: snapshot.connectivity,
                generation: snapshot.generation
            )
            emit()
        }
    }

    private func prepareRecovery() {
        snapshot = LeoSidebarSnapshot(rows: snapshot.rows, connectivity: snapshot.connectivity, generation: snapshot.generation + 1)
        activityByName = [:]
        recovering = true
        needsState = true
    }

    private func startRefresh() {
        _ = scheduler.reduce(.refreshStarted)
        refreshTask = Task { await self.performRefresh() }
    }

    private func performRefresh() async {
        defer { finishRefresh() }
        let generation = snapshot.generation
        let fetchState = needsState
        needsState = false
        do {
            let rows = try await daemon.listAgents().map(Self.row)
            guard running, generation == snapshot.generation else { return }
            snapshot = LeoSidebarReducers.applyListResult(snapshot, result: LeoSidebarReducers.mergeActivity(rows, activityByName: activityByName), generation: generation)
            recovering = false
            let buffered = bufferedActivity
            bufferedActivity = []
            buffered.forEach(applyActivity)
            emit()
            if fetchState { fetchActivityState(generation: generation) }
        } catch {
            guard running, generation == snapshot.generation else { return }
            snapshot = LeoSidebarSnapshot(rows: snapshot.rows, connectivity: .failed(message: String(describing: error)), generation: generation)
            emit()
        }
    }

    private func fetchActivityState(generation: Int) {
        activityTask?.cancel()
        activityTask = Task { [activitySource] in
            do {
                let state = try await Self.fetchState(from: activitySource)
                await self.applyActivityState(state, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
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
        process(scheduler.reduce(.refreshFinished))
    }

    private func applyActivity(_ event: LeoObserveEvent) {
        guard case let .agentActivity(_, _, name, activity, currentAction) = event else { return }
        let overlay = LeoSidebarActivity(activity: Self.activity(activity), detail: currentAction?.detail)
        activityByName[name] = overlay
        snapshot = LeoSidebarSnapshot(rows: LeoSidebarReducers.mergeActivity(snapshot.rows, activityByName: activityByName), connectivity: snapshot.connectivity, generation: snapshot.generation)
        emit()
    }

    private func emit() {
        let value = snapshot
        Task { @MainActor [sink] in sink(value) }
    }

    private func process(_ outputs: [LeoPollScheduler.Output]) {
        for output in outputs {
            switch output {
            case .refreshNow:
                startRefresh()
            case .scheduleTick(let interval):
                pollTask?.cancel()
                pollTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self.process(self.scheduler.reduce(.tick))
                }
            case .pause:
                pollTask?.cancel()
                pollTask = nil
            case .resume:
                break
            }
        }
    }

    private static func row(_ agent: LeoAgent) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: agent.name, template: agent.template, status: agent.status ?? .unknown("missing"), activity: .unknown, actionDetail: nil)
    }

    private static func activities(_ agents: [LeoObservedAgent]) -> [String: LeoSidebarActivity] {
        Dictionary(uniqueKeysWithValues: agents.map { ($0.name, LeoSidebarActivity(activity: activity($0.activity), detail: $0.currentAction?.detail)) })
    }

    private static func activity(_ activity: LeoActivity?) -> LeoAgentRow.Activity {
        switch activity {
        case .working: .working
        case .idle: .idle
        case .unknown, nil: .unknown
        }
    }
}

private enum LeoSidebarFeedError: Error { case activityStateTimedOut }
