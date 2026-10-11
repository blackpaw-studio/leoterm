import ComposableArchitecture
import Foundation
import LeoKit

/// One agent: its live state, and the control actions. Stop, restart,
/// interrupt and environment switches are confirmed first.
@Reducer
public struct AgentDetail {
    @ObservableState
    public struct State: Equatable {
        public var daemon: PairedDaemon
        public let agentName: String
        /// Kept live by the parent from `Fleet`; nil once the agent is gone.
        public var agent: Agent?
        public var connection: ConnectionStatus
        public var inFlight: AgentCommand?
        public var isLoadingEnvironments = false
        @Presents public var alert: AlertState<Never>?
        @Presents public var confirmation: ConfirmationDialogState<Action.Confirmation>?

        public init(daemon: PairedDaemon, agent: Agent, connection: ConnectionStatus) {
            self.daemon = daemon
            agentName = agent.name
            self.agent = agent
            self.connection = connection
        }

        public var ref: AgentRef { AgentRef(daemonID: daemon.id, name: agentName) }
        public var isBusy: Bool { inFlight != nil || isLoadingEnvironments }
    }

    public enum Action {
        case alert(PresentationAction<Never>)
        case commandFinished(AgentCommand, Result<Void, any Error>)
        case confirmation(PresentationAction<Confirmation>)
        case environmentsLoaded(Result<[String], any Error>)
        case interruptButtonTapped
        case openInClaudeButtonTapped
        case restartButtonTapped
        case startButtonTapped
        case stopButtonTapped
        case switchEnvironmentButtonTapped

        @CasePathable
        public enum Confirmation: Equatable {
            case perform(AgentCommand)
        }
    }

    public static let claudeCodeURL = URL(string: "https://claude.ai/code")!

    @Dependency(\.daemonClient) var daemonClient
    @Dependency(\.openURL) var openURL
    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .alert:
                return .none

            case .commandFinished(let command, .success):
                if state.inFlight == command { state.inFlight = nil }
                return .none

            case .commandFinished(let command, .failure(let error)):
                if state.inFlight == command { state.inFlight = nil }
                state.alert = Self.failureAlert("Couldn't \(command.verb) \(state.agentName)", error)
                return .none

            case .confirmation(.presented(.perform(let command))):
                return perform(command, state: &state)

            case .confirmation:
                return .none

            case .environmentsLoaded(.success(let names)):
                state.isLoadingEnvironments = false
                state.confirmation = Self.environmentPicker(names: names, current: state.agent?.environments, agent: state.agentName)
                return .none

            case .environmentsLoaded(.failure(let error)):
                state.isLoadingEnvironments = false
                state.alert = Self.failureAlert("Couldn't Load Environments", error)
                return .none

            case .interruptButtonTapped:
                state.confirmation = Self.confirmation(for: .interrupt, agent: state.agentName)
                return .none

            case .openInClaudeButtonTapped:
                let openURL = openURL
                return .run { _ in await openURL(Self.claudeCodeURL) }

            case .restartButtonTapped:
                state.confirmation = Self.confirmation(for: .restart, agent: state.agentName)
                return .none

            case .startButtonTapped:
                return perform(.start, state: &state)

            case .stopButtonTapped:
                state.confirmation = Self.confirmation(for: .stop, agent: state.agentName)
                return .none

            case .switchEnvironmentButtonTapped:
                guard !state.isBusy else { return .none }
                state.isLoadingEnvironments = true
                let (daemon, daemonClient, secrets) = (state.daemon, daemonClient, secrets)
                return .run { send in
                    await send(.environmentsLoaded(Result {
                        try await daemonClient.environmentNames(try Self.connection(daemon, secrets: secrets))
                    }))
                }
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$confirmation, action: \.confirmation)
    }

    private func perform(_ command: AgentCommand, state: inout State) -> Effect<Action> {
        guard state.inFlight == nil else { return .none }
        state.inFlight = command
        let (daemon, name, daemonClient, secrets) = (state.daemon, state.agentName, daemonClient, secrets)
        return .run { send in
            await send(.commandFinished(command, Result {
                try await daemonClient.perform(try Self.connection(daemon, secrets: secrets), name, command)
            }))
        }
    }

    private static func connection(_ daemon: PairedDaemon, secrets: SecretsClient) throws -> DaemonConnection {
        guard let saved = try secrets.load(daemon.id) else { throw MissingToken(daemonName: daemon.name) }
        return DaemonConnection(daemon: daemon, secrets: saved)
    }

    static func confirmation(for command: AgentCommand, agent: String) -> ConfirmationDialogState<Action.Confirmation> {
        let (title, message): (String, String) = switch command {
        case .stop: ("Stop \(agent)?", "The agent stops and stays stopped until you start it again.")
        case .restart: ("Restart \(agent)?", "The agent restarts and resumes its conversation.")
        case .interrupt: ("Interrupt \(agent)?", "The agent's current turn is cancelled.")
        case .start, .setEnvironments: ("\(command.verb) \(agent)?", "")
        }
        return ConfirmationDialogState(titleVisibility: .visible) {
            TextState(title)
        } actions: {
            ButtonState(role: .destructive, action: .perform(command)) { TextState(command.verb) }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState(message)
        }
    }

    static func environmentPicker(names: [String], current: LeoAgentEnvironments?, agent: String) -> ConfirmationDialogState<Action.Confirmation> {
        let isDefault = current.map { !$0.isOverride } ?? false
        let selected = current.flatMap { $0.isOverride && $0.names.count == 1 ? $0.names[0] : nil }
        return ConfirmationDialogState(titleVisibility: .visible) {
            TextState("Switch Environment")
        } actions: {
            for name in names {
                ButtonState(action: .perform(.setEnvironments([name]))) {
                    TextState(name == selected ? "\(name) (current)" : name)
                }
            }
            ButtonState(action: .perform(.setEnvironments([]))) {
                TextState(isDefault ? "Template Default (current)" : "Template Default")
            }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState("\(agent) restarts in the chosen environment and resumes its conversation.")
        }
    }

    private static func failureAlert(_ title: String, _ error: any Error) -> AlertState<Never> {
        AlertState {
            TextState(title)
        } actions: {
            ButtonState(role: .cancel) { TextState("OK") }
        } message: {
            TextState(error.localizedDescription)
        }
    }
}

struct MissingToken: LocalizedError {
    let daemonName: String
    var errorDescription: String? { "No saved token for \(daemonName). Pair it again." }
}

extension AgentCommand {
    var verb: String {
        switch self {
        case .interrupt: "Interrupt"
        case .restart: "Restart"
        case .setEnvironments: "Switch Environment for"
        case .start: "Start"
        case .stop: "Stop"
        }
    }
}
