import ComposableArchitecture
import Foundation
import LeoKit

/// One paired daemon and what the app knows about it right now.
public struct DaemonSession: Equatable, Identifiable, Sendable {
    public var daemon: PairedDaemon
    public var connection: ConnectionStatus = .offline
    public var agents: IdentifiedArrayOf<Agent> = []
    /// The daemon boot the agents' attention revisions belong to.
    public var bootID: String?
    /// Consecutive failed connection attempts; drives the backoff.
    public var failures = 0
    /// What the daemon advertised in its last `hello`.
    public var features = LeoDaemonFeatures.none
    /// The latest machine load sample; `nil` before the first, after a
    /// disconnect, and on a daemon that has none to give.
    public var stats: LeoMachineStats?
    /// The daemon answered `machine_stats_unavailable`: no meters, no polling
    /// until it reconnects.
    public var isStatsUnavailable = false
    /// Consecutive polls that got no sample; the sample is dropped once it
    /// is `Fleet.staleAfterMissedPolls` old.
    var missedStatsPolls = 0

    public var id: String { daemon.id }

    /// Whether this daemon can be asked for stats right now.
    var canPollStats: Bool {
        connection.isConnected && features.contains(.machineStats) && !isStatsUnavailable
    }

    /// The meters to draw, or `nil` when there are none (old daemon, 503,
    /// no sample yet, disconnected).
    public var meters: [MachineMeter]? {
        guard canPollStats else { return nil }
        return stats?.meters
    }

    public init(daemon: PairedDaemon) {
        self.daemon = daemon
    }
}

/// One daemon's agents as the Agents list shows them.
public struct AgentSection: Equatable, Identifiable, Sendable {
    public let daemon: PairedDaemon
    public let connection: ConnectionStatus
    public let agents: [Agent]

    public var id: String { daemon.id }

    /// The most urgent attention among the agents; every daemon without
    /// any ranks the same, so those keep name order.
    var attentionRank: AgentPriority {
        guard let first = agents.first, first.priority.needsAttention else { return .working }
        return first.priority
    }
}

/// Every paired daemon's live connection and agents, merged. Connections
/// run only while the app is active (foreground); each reconnects with
/// exponential backoff on the injected clock.
@Reducer
public struct Fleet {
    @ObservableState
    public struct State: Equatable {
        public var isActive = false
        /// The Machines list is on screen.
        public var isShowingStats = false
        @Shared(.appStorage("statsStyle")) public var statsStyle = LeoStatsStyle.default
        public var sessions: IdentifiedArrayOf<DaemonSession> = []

        public init(daemons: [PairedDaemon] = []) {
            sessions = IdentifiedArray(uniqueElements: daemons.map(DaemonSession.init))
        }

        /// Grouped by daemon. Within a daemon, agents needing the user come
        /// first; daemons with such agents come before those without.
        public var sections: [AgentSection] {
            sessions
                .map { session in
                    AgentSection(
                        daemon: session.daemon, connection: session.connection,
                        agents: session.agents.sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }
                    )
                }
                .sorted { lhs, rhs in
                    let (left, right) = (lhs.attentionRank, rhs.attentionRank)
                    if left != right { return left < right }
                    return lhs.daemon.name.localizedStandardCompare(rhs.daemon.name) == .orderedAscending
                }
        }

        /// Stats are fetched only while the Machines list is on screen, the
        /// app is active and the style draws meters.
        var pollsStats: Bool { isActive && isShowingStats && statsStyle.showsMeters }

        /// Samples are only as fresh as the polling that feeds them, so a
        /// list that isn't polling holds none: reopening it never shows an
        /// old one.
        mutating func dropStatsUnlessPolling() {
            guard !pollsStats else { return }
            for id in sessions.ids {
                sessions[id: id]?.stats = nil
                sessions[id: id]?.missedStatsPolls = 0
            }
        }

        public var attentionCount: Int {
            sessions.reduce(0) { $0 + $1.agents.filter(\.priority.needsAttention).count }
        }

        public func agent(_ ref: AgentRef) -> Agent? { sessions[id: ref.daemonID]?.agents[id: ref.name] }
    }

    public enum Action {
        case connect(DaemonSession.ID)
        case connected(DaemonSession.ID, bootID: String?, features: LeoDaemonFeatures, LeoObservedState)
        case daemonAdded(PairedDaemon)
        case daemonRemoved(DaemonSession.ID)
        case daemonsLoaded([PairedDaemon])
        case eventReceived(DaemonSession.ID, LeoObserveEvent)
        case retryButtonTapped(DaemonSession.ID)
        /// The event stream skipped a sequence number: events were lost, so
        /// anything kept from events (chat threads) should reload.
        case sequenceGap(DaemonSession.ID)
        case scenePhaseChanged(isActive: Bool)
        case snapshotLoaded(DaemonSession.ID, LeoObservedState)
        /// A poll got no sample (timeout, network); the last one stands until
        /// `staleAfterMissedPolls` in a row.
        case statsFailed(DaemonSession.ID)
        case statsLoaded(DaemonSession.ID, LeoMachineStats)
        case statsStyleChanged(LeoStatsStyle)
        case statsUnavailable(DaemonSession.ID)
        case statsVisibilityChanged(Bool)
        case streamEnded(DaemonSession.ID, StreamEnd)
        case task
    }

    enum CancelID: Hashable {
        case connection(DaemonSession.ID)
        case stats(DaemonSession.ID)
    }

    /// Seconds between stats samples while the Machines list is open.
    static let statsInterval = Duration.seconds(5)
    /// Missed polls (15s at the poll interval) after which the last sample is
    /// too old to show.
    static let staleAfterMissedPolls = 3

    @Dependency(\.continuousClock) var clock
    @Dependency(\.daemonClient) var daemonClient
    @Dependency(\.pairedDaemons) var pairedDaemons
    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .connect(let id):
                return connect(id, state: &state)

            case .sequenceGap:
                return .none

            case .connected(let id, let bootID, let features, let snapshot):
                state.sessions[id: id]?.failures = 0
                state.sessions[id: id]?.connection = .connected
                state.sessions[id: id]?.features = features
                state.sessions[id: id]?.isStatsUnavailable = false
                state.sessions[id: id]?.applySnapshot(snapshot, bootID: bootID)
                return pollStats(id, state: state)

            case .daemonAdded(let daemon):
                if state.sessions[id: daemon.id] != nil {
                    state.sessions[id: daemon.id] = DaemonSession(daemon: daemon)
                } else {
                    state.sessions.append(DaemonSession(daemon: daemon))
                }
                // A re-paired daemon starts over: its old poll must not feed
                // the new session.
                return .merge(.cancel(id: CancelID.stats(daemon.id)), save(state), connect(daemon.id, state: &state))

            case .daemonRemoved(let id):
                state.sessions.remove(id: id)
                let secrets = secrets
                return .merge(
                    .cancel(id: CancelID.connection(id)),
                    .cancel(id: CancelID.stats(id)),
                    save(state),
                    .run { _ in try secrets.delete(id) }
                )

            case .daemonsLoaded(let daemons):
                state.sessions = IdentifiedArray(daemons.map(DaemonSession.init), uniquingIDsWith: { $1 })
                return connectAll(state: &state)

            case .eventReceived(let id, let event):
                state.sessions[id: id]?.apply(event)
                return .none

            case .retryButtonTapped(let id):
                state.sessions[id: id]?.failures = 0
                return connect(id, state: &state)

            case .scenePhaseChanged(isActive: true):
                state.isActive = true
                return connectAll(state: &state)

            case .scenePhaseChanged(isActive: false):
                state.isActive = false
                for id in state.sessions.ids {
                    state.sessions[id: id]?.failures = 0
                    state.sessions[id: id]?.connection = .offline
                    state.sessions[id: id]?.stats = nil
                }
                return .merge(state.sessions.ids.flatMap { [.cancel(id: CancelID.connection($0)), .cancel(id: CancelID.stats($0))] })

            case .snapshotLoaded(let id, let snapshot):
                state.sessions[id: id]?.applySnapshot(snapshot)
                return .none

            case .statsFailed(let id):
                let missed = (state.sessions[id: id]?.missedStatsPolls ?? 0) + 1
                state.sessions[id: id]?.missedStatsPolls = missed
                if missed >= Self.staleAfterMissedPolls { state.sessions[id: id]?.stats = nil }
                return .none

            case .statsLoaded(let id, let stats):
                state.sessions[id: id]?.stats = stats
                state.sessions[id: id]?.missedStatsPolls = 0
                return .none

            case .statsStyleChanged(let style):
                state.$statsStyle.withLock { $0 = style }
                state.dropStatsUnlessPolling()
                return pollAllStats(state: state)

            case .statsUnavailable(let id):
                state.sessions[id: id]?.isStatsUnavailable = true
                state.sessions[id: id]?.stats = nil
                state.sessions[id: id]?.missedStatsPolls = 0
                return .cancel(id: CancelID.stats(id))

            case .statsVisibilityChanged(let isVisible):
                state.isShowingStats = isVisible
                state.dropStatsUnlessPolling()
                return pollAllStats(state: state)

            case .streamEnded(let id, let end):
                guard state.isActive, state.sessions[id: id] != nil else { return .none }
                state.sessions[id: id]?.stats = nil
                let stopStats: Effect<Action> = .cancel(id: CancelID.stats(id))
                switch end {
                case .unauthorized:
                    state.sessions[id: id]?.connection = .unauthorized("This device's token was rejected. Pair it again.")
                    return stopStats
                case .missingCredentials:
                    state.sessions[id: id]?.connection = .unauthorized("No saved token for this daemon. Pair it again.")
                    return stopStats
                case .closed, .failed:
                    let failures = (state.sessions[id: id]?.failures ?? 0) + 1
                    state.sessions[id: id]?.failures = failures
                    state.sessions[id: id]?.connection = .reconnecting(attempt: failures, reason: end.reason)
                    return .merge(
                        stopStats,
                        .run { [clock] send in
                            try await clock.sleep(for: Self.backoff(failures))
                            await send(.connect(id))
                        }
                        .cancellable(id: CancelID.connection(id), cancelInFlight: true)
                    )
                }

            case .task:
                let pairedDaemons = pairedDaemons
                return .run { send in
                    await send(.daemonsLoaded((try? pairedDaemons.load()) ?? []))
                }
            }
        }
    }

    /// 1s, 2s, 4s, ... capped at 30s.
    public static func backoff(_ attempt: Int) -> Duration {
        .seconds(min(30, 1 << min(max(attempt - 1, 0), 5)))
    }

    private func connectAll(state: inout State) -> Effect<Action> {
        .merge(state.sessions.ids.map { connect($0, state: &state) })
    }

    private func pollAllStats(state: State) -> Effect<Action> {
        .merge(state.sessions.ids.map { pollStats($0, state: state) })
    }

    /// Samples the daemon's load now and every `statsInterval` after, until
    /// cancelled (list hidden, app inactive, disconnect). A failed sample
    /// keeps the last one and retries on the next tick; a daemon that says it
    /// has no stats ends its own loop. Each daemon polls on its own effect,
    /// so one slow or failing machine never holds up another.
    private func pollStats(_ id: DaemonSession.ID, state: State) -> Effect<Action> {
        guard let session = state.sessions[id: id] else { return .none }
        guard state.pollsStats, session.canPollStats else { return .cancel(id: CancelID.stats(id)) }
        let (clock, daemonClient, secrets, daemon) = (clock, daemonClient, secrets, session.daemon)
        return .run { send in
            guard let saved = try secrets.load(daemon.id) else { return }
            let connection = DaemonConnection(daemon: daemon, secrets: saved)
            while !Task.isCancelled {
                do {
                    await send(.statsLoaded(id, try await daemonClient.machineStats(connection)))
                } catch LeoDaemonError.daemon(let code, _, _) where Self.endsStatsPolling(code) {
                    await send(.statsUnavailable(id))
                    return
                } catch is CancellationError {
                    return
                } catch {
                    await send(.statsFailed(id))
                }
                try await clock.sleep(for: Self.statsInterval)
            }
        } catch: { _, _ in }
        .cancellable(id: CancelID.stats(id), cancelInFlight: true)
    }

    /// The daemon says stats won't come: it has none (503), or it refuses this
    /// device's token (401/403), which polling again can't fix.
    private static func endsStatsPolling(_ code: String?) -> Bool {
        guard let code else { return false }
        return [LeoMachineStats.unavailableCode, "unauthorized", "forbidden"].contains(code)
    }

    private func save(_ state: State) -> Effect<Action> {
        let daemons = state.sessions.map(\.daemon)
        let pairedDaemons = pairedDaemons
        return .run { _ in try pairedDaemons.save(daemons) }
    }

    /// Opens the daemon's event stream. On `hello` (and on a sequence gap
    /// or a spawn) it fetches `/state` inline, so events that arrive while
    /// the snapshot loads queue up and apply after it. The session counts
    /// as connected only once the `hello` snapshot has loaded.
    private func connect(_ id: DaemonSession.ID, state: inout State) -> Effect<Action> {
        guard state.isActive, let session = state.sessions[id: id] else { return .none }
        if session.failures == 0 { state.sessions[id: id]?.connection = .connecting }
        let daemon = session.daemon
        let (daemonClient, secrets) = (daemonClient, secrets)
        return .run { send in
            guard let saved = try secrets.load(daemon.id) else {
                await send(.streamEnded(id, .missingCredentials))
                return
            }
            let connection = DaemonConnection(daemon: daemon, secrets: saved)
            var lastSequence: Int?
            for try await event in daemonClient.events(connection) {
                let sequence = event.sequence
                if case .hello(_, _, _, _, let bootID, let features) = event {
                    await send(.connected(id, bootID: bootID, features: LeoDaemonFeatures(features), try await daemonClient.fetchState(connection)))
                    lastSequence = sequence
                    continue
                }
                if sequence >= 0, let lastSequence, sequence > lastSequence + 1 {
                    await send(.sequenceGap(id))
                    await send(.snapshotLoaded(id, try await daemonClient.fetchState(connection)))
                }
                if sequence >= 0 { lastSequence = sequence }
                await send(.eventReceived(id, event))
                if case .agentSpawned = event {
                    await send(.snapshotLoaded(id, try await daemonClient.fetchState(connection)))
                }
            }
            await send(.streamEnded(id, .closed))
        } catch: { error, send in
            await send(.streamEnded(id, StreamEnd(error)))
        }
        .cancellable(id: CancelID.connection(id), cancelInFlight: true)
    }
}

extension StreamEnd {
    init(_ error: any Error) {
        switch error {
        case LeoDaemonError.daemon(let code, let message, _) where code == "unauthorized" || code == "forbidden":
            self = .unauthorized(message)
        case LeoDaemonError.transport(let reason):
            self = .failed(reason)
        case LeoDaemonError.timeout:
            self = .failed("The daemon stopped responding")
        default:
            self = .failed(error.localizedDescription)
        }
    }

    var reason: String {
        switch self {
        case .closed: "Connection closed"
        case .failed(let reason), .unauthorized(let reason): reason
        case .missingCredentials: "No saved token"
        }
    }
}

extension DaemonSession {
    /// Replaces the agents with the snapshot's, keeping any attention
    /// already seen at a newer revision (an event that raced the fetch).
    /// Revisions restart with the daemon, so a new `bootID` discards the
    /// attention seen before it.
    mutating func applySnapshot(_ snapshot: LeoObservedState, bootID: String? = nil) {
        if let bootID, bootID != self.bootID {
            self.bootID = bootID
            agents = []
        }
        let previous = agents
        agents = IdentifiedArray(
            snapshot.agents.map { observed in
                var agent = Agent(observed)
                if let known = previous[id: observed.name]?.attention,
                   known.revision > (agent.attention?.revision ?? Int.min) {
                    agent.attention = known
                }
                return agent
            },
            uniquingIDsWith: { $1 }
        )
    }

    mutating func apply(_ event: LeoObserveEvent) {
        switch event {
        case .agentSpawned(_, _, let spawned, let attention, let environments):
            var agent = agents[id: spawned.name] ?? Agent(name: spawned.name)
            agent.status = spawned.status ?? .starting
            agent.template = spawned.template ?? agent.template
            agent.startedAt = spawned.startedAt ?? agent.startedAt
            agent.adopt(attention)
            if let environments { agent.environments = environments.applied(to: agent.environments) }
            agents[id: spawned.name] = agent

        case .agentStateChanged(_, _, let name, let status, _, _, let environments):
            update(name) { agent in
                if let status { agent.status = status }
                if let environments { agent.environments = environments.applied(to: agent.environments) }
            }

        case .agentActivity(_, _, let name, let activity, let currentAction, let attention):
            update(name) { agent in
                agent.activity = activity
                agent.currentAction = currentAction
                agent.adopt(attention)
            }

        case .agentStopped(_, _, let name, _):
            update(name) { agent in
                agent.status = .stopped
                agent.activity = .unknown
                agent.currentAction = nil
            }

        case .snapshot(let observed):
            applySnapshot(LeoObservedState(agents: observed))

        case .connected, .disconnected, .hello, .gap, .dispatchChanged, .dispatchRemoved,
             .agentTurnCompleted, .agentUsage, .agentCompaction, .chat, .other:
            return
        }
    }

    /// Edits a known agent; an event for an agent not in the snapshot is
    /// ignored (the next snapshot brings it).
    private mutating func update(_ name: String, _ change: (inout Agent) -> Void) {
        guard var agent = agents[id: name] else { return }
        change(&agent)
        agents[id: name] = agent
    }
}
