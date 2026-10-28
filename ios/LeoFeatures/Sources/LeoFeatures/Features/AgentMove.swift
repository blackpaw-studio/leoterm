import ComposableArchitecture
import Foundation
import LeoKit

/// B-324: move, copy or duplicate one agent. A move is confirmed first; a
/// copy asks for an optional name. The daemon runs the job and `daemonClient
/// .move` follows it to its outcome, so a refusal (a busy agent, an
/// unreachable host) arrives here with the daemon's own text. A mid-turn move
/// offers Force.
@Reducer
public struct AgentMove {
    public enum Intent: Equatable, Sendable {
        case move(to: String)
        case copy(to: String)
        /// A copy on the agent's own host.
        case duplicate
    }

    @ObservableState
    public struct State: Equatable, Identifiable {
        /// Fresh per flow, so replacing or dropping a flow cancels its effects.
        /// Not part of equality: two flows for the same move compare equal.
        public let id = UUID()
        public var daemon: PairedDaemon
        public let agentName: String
        public let intent: Intent
        public var isMoving = false
        /// The UIKit layer shows the name prompt while this is set.
        public var isAskingName = false
        @Presents public var alert: AlertState<Never>?
        @Presents public var confirmation: ConfirmationDialogState<Action.Confirmation>?

        public init(daemon: PairedDaemon, agentName: String, intent: Intent) {
            self.daemon = daemon
            self.agentName = agentName
            self.intent = intent
            switch intent {
            case .move: confirmation = AgentMove.confirmation(for: intent, agent: agentName)
            case .copy, .duplicate: isAskingName = true
            }
        }

        public var ref: AgentRef { AgentRef(daemonID: daemon.id, name: agentName) }

        public static func == (lhs: State, rhs: State) -> Bool {
            lhs.daemon == rhs.daemon && lhs.agentName == rhs.agentName && lhs.intent == rhs.intent
                && lhs.isMoving == rhs.isMoving && lhs.isAskingName == rhs.isAskingName
                && lhs.alert == rhs.alert && lhs.confirmation == rhs.confirmation
        }
    }

    public enum Action {
        case alert(PresentationAction<Never>)
        case confirmation(PresentationAction<Confirmation>)
        case delegate(Delegate)
        case finished(Result<LeoAgentMoveOutcome, any Error>)
        case nameCancelled
        case nameSubmitted(String)

        @CasePathable
        public enum Confirmation: Equatable {
            case start(force: Bool)
        }

        @CasePathable
        public enum Delegate: Equatable {
            /// The daemon changed (or may have changed) the fleet: refetch it.
            case completed
            /// Nothing more to show; the parent drops this flow.
            case dismissed
        }
    }

    @Dependency(\.daemonClient) var daemonClient
    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .alert(.dismiss):
                return .send(.delegate(.dismissed))

            case .alert, .delegate:
                return .none

            case .confirmation(.presented(.start(let force))):
                guard case .move(let host) = state.intent else { return .none }
                return start(.move(to: host, force: force), state: &state)

            case .confirmation(.dismiss):
                return state.isMoving ? .none : .send(.delegate(.dismissed))

            case .nameSubmitted(let name):
                state.isAskingName = false
                switch state.intent {
                case .copy(let host): return start(.copy(to: host, name: name), state: &state)
                case .duplicate: return start(.duplicate(name: name), state: &state)
                case .move: return .none
                }

            case .nameCancelled:
                state.isAskingName = false
                return .send(.delegate(.dismissed))

            case .finished(.success(let outcome)):
                state.isMoving = false
                return finish(outcome, state: &state)

            case .finished(.failure(let error)):
                state.isMoving = false
                guard !(error is CancellationError) else { return .none }
                state.alert = Self.failureAlert("Couldn't \(state.verb) \(state.agentName)", error.localizedDescription)
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$confirmation, action: \.confirmation)
    }

    private func start(_ request: LeoMoveRequest, state: inout State) -> Effect<Action> {
        guard !state.isMoving else { return .none }
        state.confirmation = nil
        state.isMoving = true
        let (daemon, name, daemonClient, secrets) = (state.daemon, state.agentName, daemonClient, secrets)
        return .run { send in
            await send(.finished(Result {
                guard let saved = try secrets.load(daemon.id) else { throw MissingToken(daemonName: daemon.name) }
                return try await daemonClient.move(DaemonConnection(daemon: daemon, secrets: saved), name, request)
            }))
        }
    }

    private func finish(_ outcome: LeoAgentMoveOutcome, state: inout State) -> Effect<Action> {
        switch outcome {
        case .done:
            return .send(.delegate(.completed))
        case .refused(_, let message, let offersForce):
            if offersForce {
                state.confirmation = Self.busyConfirmation(agent: state.agentName, message: message)
            } else {
                state.alert = Self.failureAlert("Couldn't \(state.verb) \(state.agentName)", message)
            }
            return .none
        case .unknown(let message):
            state.alert = Self.failureAlert("Couldn't confirm the \(state.noun) of \(state.agentName)", message)
            return .send(.delegate(.completed))
        }
    }

    static func confirmation(for intent: Intent, agent: String) -> ConfirmationDialogState<Action.Confirmation> {
        let host: String
        if case .move(let to) = intent { host = to } else { host = "" }
        return ConfirmationDialogState(titleVisibility: .visible) {
            TextState("Move \(agent) to \(host)?")
        } actions: {
            ButtonState(action: .start(force: false)) { TextState("Move") }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState("It stops here and resumes there.")
        }
    }

    static func busyConfirmation(agent: String, message: String) -> ConfirmationDialogState<Action.Confirmation> {
        ConfirmationDialogState(titleVisibility: .visible) {
            TextState("\(agent) is busy")
        } actions: {
            ButtonState(role: .destructive, action: .start(force: true)) { TextState("Move Anyway") }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState(message)
        }
    }

    static func failureAlert(_ title: String, _ message: String) -> AlertState<Never> {
        AlertState {
            TextState(title)
        } actions: {
            ButtonState(role: .cancel) { TextState("OK") }
        } message: {
            TextState(message)
        }
    }
}

extension AgentMove.State {
    fileprivate var verb: String {
        switch intent {
        case .move: "move"
        case .copy: "copy"
        case .duplicate: "duplicate"
        }
    }

    fileprivate var noun: String {
        if case .move = intent { "move" } else { "copy" }
    }
}
