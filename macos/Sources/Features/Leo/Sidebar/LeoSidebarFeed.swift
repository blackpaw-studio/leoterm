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
    private var pollTask: Task<Void, Never>?
    private var scheduler = LeoPollScheduler()
    private var running = false
    private var refreshing = false
    private var refreshPending = false
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
        pollTask?.cancel()
        eventTask = nil
        refreshTask = nil
        pollTask = nil
        refreshing = false
        refreshPending = false
    }

    func refresh() { requestRefresh(recovering: false) }

    func setPolling(_ pollable: Bool) {
        guard running else { return }
        process(scheduler.reduce(.sidebarVisibleCountChanged(pollable ? 1 : 0)))
    }

    func receive(_ event: LeoObserveEvent) {
        guard running else { return }
        switch event {
        case .connected, .hello, .gap, .snapshot:
            requestRefresh(recovering: true)
        case .agentSpawned, .agentStateChanged, .agentStopped:
            requestRefresh(recovering: false)
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

    private func requestRefresh(recovering shouldRecover: Bool) {
        guard running else { return }
        if shouldRecover {
            snapshot = LeoSidebarSnapshot(rows: snapshot.rows, connectivity: snapshot.connectivity, generation: snapshot.generation + 1)
            activityByName = [:]
            recovering = true
            needsState = true
        }
        guard !refreshing else { refreshPending = true; return }
        refreshing = true
        _ = scheduler.reduce(.refreshStarted)
        refreshTask = Task { await self.performRefresh() }
    }

    private func performRefresh() async {
        defer { finishRefresh() }
        let generation = snapshot.generation
        let fetchState = needsState
        needsState = false
        do {
            async let agents = daemon.listAgents()
            async let observed = fetchState ? activitySource.fetchState() : []
            let rows = try await agents.map(Self.row)
            let state = try await observed
            guard running, generation == snapshot.generation else { return }
            if fetchState { activityByName = Self.activities(state) }
            snapshot = LeoSidebarReducers.applyListResult(snapshot, result: LeoSidebarReducers.mergeActivity(rows, activityByName: activityByName), generation: generation)
            recovering = false
            let buffered = bufferedActivity
            bufferedActivity = []
            buffered.forEach(applyActivity)
            emit()
        } catch {
            guard running, generation == snapshot.generation else { return }
            snapshot = LeoSidebarSnapshot(rows: snapshot.rows, connectivity: .failed(message: String(describing: error)), generation: generation)
            emit()
        }
    }

    private func finishRefresh() {
        refreshing = false
        refreshTask = nil
        process(scheduler.reduce(.refreshFinished))
        if refreshPending {
            refreshPending = false
            requestRefresh(recovering: false)
        }
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
                requestRefresh(recovering: false)
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
