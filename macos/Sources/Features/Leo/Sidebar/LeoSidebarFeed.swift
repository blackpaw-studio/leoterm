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

actor LeoSidebarFeed {
    typealias Sink = @MainActor @Sendable (LeoSidebarSnapshot) -> Void
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "LeoSidebarFeed")

    private let daemon: any LeoDaemonClient
    private let activitySource: LeoSidebarActivitySource
    private let sink: Sink
    private let sleeper: @Sendable (UInt64) async throws -> Void
    private var snapshot = LeoSidebarSnapshot(rows: [], connectivity: .loading, generation: 0)
    private var activityByName: [String: LeoSidebarActivity] = [:]
    private var bufferedActivity: [LeoObserveEvent] = []
    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var emissionTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var scheduler = LeoPollScheduler()
    private var running = false
    private var needsState = true
    private var recovering = false
    private var awaitingHello = false

    init(daemon: any LeoDaemonClient, activity: LeoSidebarActivitySource, sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }, sink: @escaping Sink) {
        self.daemon = daemon
        activitySource = activity
        sleeper = sleep
        self.sink = sink
    }

    func start() {
        guard !running else { return }
        running = true
        eventTask = Task { [weak self, activitySource] in
            let events = await activitySource.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.receive(event)
            }
        }
    }

    func stop() {
        running = false
        eventTask?.cancel()
        refreshTask?.cancel()
        activityTask?.cancel()
        emissionTask?.cancel()
        pollTask?.cancel()
        eventTask = nil
        refreshTask = nil
        activityTask = nil
        emissionTask = nil
        pollTask = nil
        scheduler.reset()
    }

    func refresh() {
        guard running else { return }
        process(scheduler.reduce(.refreshRequested))
    }

    func tick() {
        guard running else { return }
        process(scheduler.reduce(.tick))
    }

    func setPolling(_ pollable: Bool) {
        guard running else { return }
        process(scheduler.reduce(.sidebarVisibleCountChanged(pollable ? 1 : 0)))
    }

    func receive(_ event: LeoObserveEvent) {
        guard running else { return }
        switch event {
        case .connected:
            guard !recovering else { return }
            awaitingHello = true
            prepareRecovery()
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
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
    }

    private func performRefresh() async {
        var wasCancelled = false
        defer {
            if !wasCancelled { finishRefresh() }
        }
        let generation = snapshot.generation
        let fetchState = needsState
        needsState = false
        do {
            let rows = try await fetchList().map(Self.row)
            guard running, generation == snapshot.generation else { return }
            snapshot = LeoSidebarReducers.applyListResult(snapshot, result: LeoSidebarReducers.mergeActivity(rows, activityByName: activityByName), generation: generation)
            recovering = false
            let buffered = bufferedActivity
            bufferedActivity = []
            buffered.forEach(applyActivity)
            emit()
            if fetchState { fetchActivityState(generation: generation) }
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            guard running, generation == snapshot.generation else { return }
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

    private func emit() {
        let value = snapshot
        let previous = emissionTask
        emissionTask = Task { [weak self, sink] in
            await previous?.value
            guard !Task.isCancelled, self != nil else { return }
            await sink(value)
        }
    }

    private func process(_ outputs: [LeoPollScheduler.Output]) {
        for output in outputs {
            switch output {
            case .refreshNow:
                guard running else { continue }
                startRefresh()
            case .scheduleTick(let interval):
                pollTask?.cancel()
                pollTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
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

private final class LeoListFetchRace: @unchecked Sendable {
    enum Winner { case list, deadline }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<[LeoAgent], Error>, Never>?
    private var listTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Result<[LeoAgent], Error>, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func install(listTask: Task<Void, Never>, deadlineTask: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            self.listTask = listTask
            self.deadlineTask = deadlineTask
            return finished
        }
        if shouldCancel {
            listTask.cancel()
            deadlineTask.cancel()
        }
    }

    func finish(_ result: Result<[LeoAgent], Error>, winner: Winner) {
        let resolution = lock.withLock { () -> (CheckedContinuation<Result<[LeoAgent], Error>, Never>, Task<Void, Never>?)? in
            guard !finished, let continuation else { return nil }
            finished = true
            self.continuation = nil
            let loser = switch winner {
            case .list: deadlineTask
            case .deadline: listTask
            }
            return (continuation, loser)
        }
        resolution?.0.resume(returning: result)
        resolution?.1?.cancel()
    }

    func cancel() {
        let resolution = lock.withLock { () -> (CheckedContinuation<Result<[LeoAgent], Error>, Never>?, Task<Void, Never>?, Task<Void, Never>?) in
            guard !finished else { return (nil, nil, nil) }
            finished = true
            let continuation = continuation
            self.continuation = nil
            return (continuation, listTask, deadlineTask)
        }
        resolution.0?.resume(returning: .failure(CancellationError()))
        resolution.1?.cancel()
        resolution.2?.cancel()
    }
}

private enum LeoSidebarFeedError: Error, LocalizedError {
    case activityStateTimedOut
    case listTimedOut

    var errorDescription: String? {
        switch self {
        case .activityStateTimedOut, .listTimedOut: "timed out"
        }
    }
}
