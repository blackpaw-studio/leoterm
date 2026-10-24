import ComposableArchitecture
import Foundation
import LeoKit

/// The machine-level operations on its daemon: Restart Daemon, Restart All
/// Agents and Reload Config. It belongs to `MachineSettings`, not to a pane,
/// so a restart outlives the screen that asked for it, and the Service
/// screen and every config pane's restart banner ask the same place.
///
/// Every restart asks the daemon for a fresh status first (the agent count
/// the question names, and the process a restart is told apart from), then
/// confirms. A daemon restart drops this app's connection, so after the
/// daemon accepts it the wait polls the status until the process is a new
/// one, riding out the connection being down (`LeoRestartWait` reads each
/// poll). The daemon allows one restart at a time: a second request is a 409
/// `restart_in_progress`, shown as a restart under way, not a failure.
@Reducer
public struct MachineRestart {
    public enum Kind: Equatable, Sendable {
        case daemon
        case agents
    }

    @ObservableState
    public struct State: Equatable {
        public enum Phase: Equatable, Sendable {
            case idle
            /// Reading the status the question is about.
            case checking
            /// A request is out.
            case working
            /// The daemon accepted a restart; `waitingOnAgents`: it is still
            /// answering as the old process while busy agents pause.
            case restarting(waitingOnAgents: Bool)
        }

        public var machine: String
        public var connection: DaemonConnection?
        public var phase = Phase.idle
        public var notice: String?
        public var errorMessage: String?
        public var agentsSummary: String?
        /// The process the daemon was before the restart it is waiting out.
        var restartPrevious: LeoServiceStatus?
        /// The wait was stopped because the app left the foreground.
        var isWaitSuspended = false
        @Presents public var alert: AlertState<Action.Alert>?

        public init(machine: String, connection: DaemonConnection? = nil) {
            self.machine = machine
            self.connection = connection
        }

        public var isBusy: Bool { phase != .idle }

        public var isRestarting: Bool {
            if case .restarting = phase { true } else { false }
        }

        public var isWaitingOnAgents: Bool {
            if case .restarting(waitingOnAgents: true) = phase { true } else { false }
        }

        /// What the screens show while a restart waits.
        public static let waitingOnAgentsText = "Waiting for busy agents to pause…"
    }

    public enum Action {
        case requested(Kind)
        case reloadRequested
        case statusChecked(Kind, Result<LeoServiceStatus, Error>)
        case alert(PresentationAction<Alert>)
        case restartAccepted(previous: LeoServiceStatus?, alreadyRunning: Bool)
        case requestFailed(String)
        case waitProgress(onAgents: Bool)
        case waitEnded(Wait)
        case agentsRestarted(Result<LeoAgentsRestartResult, Error>)
        case reloaded(Result<LeoConfigReload, Error>)
        case dismissMessages
        /// The app left or returned to the foreground.
        case scenePhaseChanged(isActive: Bool)
        case delegate(Delegate)

        /// The buttons carry what the question was asked about: the alert has
        /// closed by the time they run.
        @CasePathable
        public enum Alert: Equatable, Sendable {
            case restartDaemon(previous: LeoServiceStatus?)
            case restartAgents
        }

        public enum Wait: Equatable, Sendable {
            case restarted
            case gaveUp(afterDown: Bool)
        }

        @CasePathable
        public enum Delegate: Equatable {
            /// An operation ended: the status on screen is stale.
            case finished
        }
    }

    enum CancelID: Hashable {
        case wait
    }

    @Dependency(\.configClients) var configClients
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .requested(let kind):
                return check(&state, kind)
            case .reloadRequested:
                return reload(&state)
            case .statusChecked(let kind, let result):
                state.phase = .idle
                state.alert = Self.alert(kind, machine: state.machine, status: try? result.get())
                return .none
            case .alert(.presented(.restartDaemon(let previous))):
                return restartDaemon(&state, previous: previous)
            case .alert(.presented(.restartAgents)):
                return restartAgents(&state)
            case .alert:
                return .none
            case .restartAccepted(let previous, let alreadyRunning):
                state.notice = alreadyRunning ? "A restart is already in progress on \(state.machine)." : nil
                state.phase = .restarting(waitingOnAgents: false)
                state.restartPrevious = previous
                state.isWaitSuspended = false
                return wait(state, previous: previous)
            case .requestFailed(let message):
                state.phase = .idle
                state.errorMessage = message
                state.alert = Self.result("Couldn’t restart", message)
                return .none
            case .waitProgress(let onAgents):
                guard state.isRestarting else { return .none }
                state.phase = .restarting(waitingOnAgents: onAgents)
                return .none
            case .waitEnded(let outcome):
                state.phase = .idle
                state.restartPrevious = nil
                state.isWaitSuspended = false
                switch outcome {
                case .restarted:
                    state.notice = "leo restarted on \(state.machine)."
                    state.alert = Self.result("Restarted", state.notice)
                case .gaveUp(let afterDown):
                    state.errorMessage = LeoServiceText.gaveUp(afterDown: afterDown, machine: state.machine)
                    state.alert = Self.result("The restart hasn’t finished", state.errorMessage)
                }
                return .send(.delegate(.finished))
            case .agentsRestarted(let result):
                state.phase = .idle
                switch result {
                case .success(let restart):
                    state.agentsSummary = LeoServiceText.summary(of: restart)
                    state.alert = Self.result(restart.hasFailures ? "Some agents didn’t restart" : "Agents restarted", state.agentsSummary)
                case .failure(let error):
                    state.errorMessage = LeoConfigCollectionState.message(for: error)
                    state.alert = Self.result("Couldn’t restart agents", state.errorMessage)
                }
                return .send(.delegate(.finished))
            case .reloaded(let result):
                state.phase = .idle
                switch result {
                case .success(let reload):
                    if let warning = reload.warning {
                        state.errorMessage = warning
                        state.alert = Self.result("Reloaded with a warning", warning)
                    } else {
                        state.notice = "Configuration reloaded on \(state.machine)."
                        state.alert = Self.result("Reloaded", state.notice)
                    }
                case .failure(let error):
                    state.errorMessage = LeoConfigCollectionState.message(for: error)
                    state.alert = Self.result("Couldn’t reload", state.errorMessage)
                }
                return .send(.delegate(.finished))
            case .dismissMessages:
                Self.clearMessages(&state)
                return .none
            case .scenePhaseChanged(let isActive):
                return scenePhaseChanged(&state, isActive: isActive)
            case .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    private static func daemonRestartMessage(running: Int?) -> String {
        switch running {
        case nil: "Running agents keep their tmux sessions."
        case 1?: "1 running agent keeps its tmux sessions."
        case let count?: "\(count) running agents keep their tmux sessions."
        }
    }

    /// The wait doesn't run in the background: the deadline is wall-clock, and
    /// a poll that fails because the app was suspended says nothing about the
    /// daemon. It stops there (the restart stays "under way", with the process
    /// it is told apart from) and starts again, with a full deadline, on return.
    private func scenePhaseChanged(_ state: inout State, isActive: Bool) -> Effect<Action> {
        guard state.isRestarting else { return .none }
        if !isActive {
            state.isWaitSuspended = true
            return .cancel(id: CancelID.wait)
        }
        guard state.isWaitSuspended else { return .none }
        state.isWaitSuspended = false
        return wait(state, previous: state.restartPrevious)
    }

    /// What an operation ended with, for screens that can't show it inline.
    private static func result(_ title: String, _ message: String?) -> AlertState<Action.Alert> {
        AlertState {
            TextState(title)
        } actions: {
            ButtonState(role: .cancel) { TextState("OK") }
        } message: {
            TextState(message ?? "")
        }
    }

    private static func clearMessages(_ state: inout State) {
        state.notice = nil
        state.errorMessage = nil
        state.agentsSummary = nil
    }

    // MARK: asking

    /// Reads the status the question is about, then asks it.
    private func check(_ state: inout State, _ kind: Kind) -> Effect<Action> {
        guard !state.isBusy else {
            state.alert = Self.result("A restart is already in progress", "leo on \(state.machine) is already restarting.")
            return .none
        }
        guard let client = client(state) else { return .none }
        state.phase = .checking
        Self.clearMessages(&state)
        return .run { send in
            await send(.statusChecked(kind, await Result { try await client.serviceStatus() }))
        }
    }

    private func client(_ state: State) -> (any LeoConfigClient)? {
        state.connection.map(configClients.client)
    }

    private static func alert(_ kind: Kind, machine: String, status: LeoServiceStatus?) -> AlertState<Action.Alert> {
        switch kind {
        case .daemon:
            AlertState {
                TextState("Restart leo on \(machine)?")
            } actions: {
                ButtonState(role: .destructive, action: .restartDaemon(previous: status)) { TextState("Restart") }
                ButtonState(role: .cancel) { TextState("Cancel") }
            } message: {
                TextState(Self.daemonRestartMessage(running: status?.runningAgentCount))
            }
        case .agents:
            AlertState {
                TextState("Restart all agents on \(machine)?")
            } actions: {
                ButtonState(role: .destructive, action: .restartAgents) { TextState("Restart All Agents") }
                ButtonState(role: .cancel) { TextState("Cancel") }
            } message: {
                TextState(LeoServiceText.agentsRestartMessage(running: status?.runningAgentCount))
            }
        }
    }

    // MARK: doing

    /// Asks the daemon to restart; one that is already running counts as started.
    private func restartDaemon(_ state: inout State, previous: LeoServiceStatus?) -> Effect<Action> {
        guard !state.isBusy, let client = client(state) else { return .none }
        state.phase = .working
        Self.clearMessages(&state)
        return .run { send in
            do {
                _ = try await client.restartService()
                await send(.restartAccepted(previous: previous, alreadyRunning: false))
            } catch where LeoServiceError.isRestartInProgress(error) {
                await send(.restartAccepted(previous: previous, alreadyRunning: true))
            } catch {
                await send(.requestFailed(LeoConfigCollectionState.message(for: error)))
            }
        }
    }

    private func restartAgents(_ state: inout State) -> Effect<Action> {
        guard !state.isBusy, let client = client(state) else { return .none }
        state.phase = .working
        Self.clearMessages(&state)
        return .run { send in
            await send(.agentsRestarted(await Result { try await client.restartAgents() }))
        }
    }

    private func reload(_ state: inout State) -> Effect<Action> {
        guard !state.isBusy, let client = client(state) else { return .none }
        state.phase = .working
        Self.clearMessages(&state)
        return .run { send in
            await send(.reloaded(await Result { try await client.reloadConfig() }))
        }
    }

    /// Polls until the daemon is a new process. `LeoRestartWait` reads each
    /// poll; the deadline is checked before every poll, because same-process
    /// polls (busy agents draining) never spend the unreachable budget.
    private func wait(_ state: State, previous: LeoServiceStatus?) -> Effect<Action> {
        guard let client = client(state) else { return .none }
        let (clock, date) = (clock, date)
        return .run { send in
            var wait = LeoRestartWait(previous: previous, startedAt: date.now)
            while true {
                do { try await clock.sleep(for: LeoServicePane.restartPollInterval) } catch { return }
                if case .gaveUp(let afterDown)? = wait.expiry(at: date.now) {
                    await send(.waitEnded(.gaveUp(afterDown: afterDown)))
                    return
                }
                let poll = await Result { try await client.serviceStatus() }
                guard !Task.isCancelled else { return }
                switch wait.record(poll) {
                case .waiting(let onAgents):
                    await send(.waitProgress(onAgents: onAgents))
                case .restarted:
                    await send(.waitEnded(.restarted))
                    return
                case .gaveUp(let afterDown):
                    await send(.waitEnded(.gaveUp(afterDown: afterDown)))
                    return
                }
            }
        }
        .cancellable(id: CancelID.wait, cancelInFlight: true)
    }
}
