import ComposableArchitecture
import Foundation

/// The app root: the fleet of daemons, the Daemons screen, the selected
/// agent, and the pairing sheet.
@Reducer
public struct AppFeature {
    @ObservableState
    public struct State: Equatable {
        public var daemons = Daemons.State()
        /// The selected agent. Selection, not presentation: on iPhone the
        /// split view collapses it onto the list's navigation stack.
        public var detail: AgentDetail.State?
        public var fleet = Fleet.State()
        public var isShowingDaemons = false
        @Presents public var pairing: Pairing.State?

        public init() {}
    }

    public enum Action: BindableAction {
        case agentTapped(AgentRef)
        case binding(BindingAction<State>)
        case daemons(Daemons.Action)
        case daemonsButtonTapped
        case detail(AgentDetail.Action)
        case fleet(Fleet.Action)
        case pairButtonTapped
        case pairing(PresentationAction<Pairing.Action>)
        case scenePhaseChanged(isActive: Bool)
        case task
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.fleet, action: \.fleet) { Fleet() }
        Scope(state: \.daemons, action: \.daemons) { Daemons() }
        Reduce { state, action in
            switch action {
            case .agentTapped(let ref):
                guard let session = state.fleet.sessions[id: ref.daemonID],
                      let agent = session.agents[id: ref.name] else { return .none }
                if state.detail?.ref != ref {
                    state.detail = AgentDetail.State(daemon: session.daemon, agent: agent, connection: session.connection)
                }
                return .none

            case .daemons(.delegate(.add)), .pairButtonTapped:
                state.pairing = Pairing.State()
                return .none

            case .daemons(.delegate(.forget(let id))):
                if state.detail?.daemon.id == id { state.detail = nil }
                return fleet(.daemonRemoved(id), state: &state)

            case .daemons(.delegate(.retry(let id))):
                return fleet(.retryButtonTapped(id), state: &state)

            case .daemonsButtonTapped:
                state.isShowingDaemons = true
                return .none

            case .pairing(.presented(.delegate(.paired(let daemon)))):
                state.pairing = nil
                return fleet(.daemonAdded(daemon), state: &state)

            case .pairing(.presented(.delegate(.cancel))):
                state.pairing = nil
                return .none

            case .detail(.destination(.presented(.files(.delegate(.opened(let file)))))):
                guard let id = state.detail?.daemon.id else { return .none }
                return fleet(.fileOpened(id, file), state: &state)

            case .scenePhaseChanged(let isActive):
                let terminal: Effect<Action> = state.detail?.destination?.terminal == nil
                    ? .none
                    : .send(.detail(.destination(.presented(.terminal(.scenePhaseChanged(isActive: isActive))))))
                return .merge(fleet(.scenePhaseChanged(isActive: isActive), state: &state), terminal)

            case .task:
                return fleet(.task, state: &state)

            case .binding, .daemons, .detail, .fleet, .pairing:
                return .none
            }
        }
        .ifLet(\.$pairing, action: \.pairing) { Pairing() }
        .ifLet(\.detail, action: \.detail) { AgentDetail() }
        Reduce { state, _ in
            state.syncDetail()
            // The terminal opens and closes its socket as the agent starts
            // and stops, so that change is an action, not a state edit.
            guard let terminal = state.detail?.destination?.terminal, let agent = state.detail?.agent,
                  terminal.isAgentRunning == agent.isStopped else { return .none }
            return .send(.detail(.destination(.presented(.terminal(.agentRunningChanged(!agent.isStopped))))))
        }
    }

    private func fleet(_ action: Fleet.Action, state: inout State) -> Effect<Action> {
        Fleet().reduce(into: &state.fleet, action: action).map(Action.fleet)
    }
}

extension AppFeature.State {
    /// Keeps the open detail in step with the live fleet.
    mutating func syncDetail() {
        guard let ref = detail?.ref, let session = fleet.sessions[id: ref.daemonID] else { return }
        let agent = session.agents[id: ref.name]
        if detail?.agent != agent { detail?.agent = agent }
        if detail?.connection != session.connection { detail?.connection = session.connection }
        if detail?.daemon != session.daemon { detail?.daemon = session.daemon }
        let (files, unseen) = (fleet.surfacedFiles(for: ref), fleet.unseenFileIDs(for: ref))
        detail?.syncFiles(files, unseen: unseen)
    }
}
