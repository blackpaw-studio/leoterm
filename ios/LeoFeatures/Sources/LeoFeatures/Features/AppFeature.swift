import ComposableArchitecture
import Foundation

/// The app root: the fleet of daemons, the Daemons screen, the selected
/// agent, the pairing sheet, Settings and push registration.
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
        public var isShowingSettings = false
        @Presents public var pairing: Pairing.State?
        public var push = PushNotifications.State()
        /// Whether the paired daemons have been read from disk yet.
        public var hasLoadedDaemons = false
        /// A tapped notification's agent, opened once the fleet has it.
        public var pendingAgent: AgentRef?

        public init() {}
    }

    public enum Action: BindableAction {
        case agentTapped(AgentRef)
        case binding(BindingAction<State>)
        case daemons(Daemons.Action)
        case daemonsButtonTapped
        case detail(AgentDetail.Action)
        case fleet(Fleet.Action)
        /// A tapped notification (the app may have just launched for it).
        case notificationOpened(AgentRef)
        case pairButtonTapped
        case pairing(PresentationAction<Pairing.Action>)
        case push(PushNotifications.Action)
        case scenePhaseChanged(isActive: Bool)
        case settingsButtonTapped
        case task
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        CombineReducers {
            BindingReducer()
            Scope(state: \.fleet, action: \.fleet) { Fleet() }
            Scope(state: \.daemons, action: \.daemons) { Daemons() }
            Scope(state: \.push, action: \.push) { PushNotifications() }
            Reduce { state, action in
                switch action {
                case .agentTapped(let ref):
                    state.pendingAgent = nil
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
                    guard let daemon = state.fleet.sessions[id: id]?.daemon else { return fleet(.daemonRemoved(id), state: &state) }
                    // Push reads the daemon's token before the removal deletes it.
                    return .concatenate(push(.daemonForgotten(daemon), state: &state), fleet(.daemonRemoved(id), state: &state))

                case .daemons(.delegate(.retry(let id))):
                    return fleet(.retryButtonTapped(id), state: &state)

                case .daemonsButtonTapped:
                    state.isShowingDaemons = true
                    return .none

                case .fleet(.connected(let id, _, _)):
                    return push(.daemonReconnected(id), state: &state)

                case .fleet(.daemonsLoaded(let daemons, _)):
                    state.hasLoadedDaemons = true
                    return push(.daemonsLoaded(daemons), state: &state)

                case .notificationOpened(let ref):
                    state.pendingAgent = ref
                    return .none

                case .pairing(.presented(.delegate(.paired(let daemon)))):
                    state.pairing = nil
                    return .merge(fleet(.daemonAdded(daemon), state: &state), push(.daemonPaired(daemon), state: &state))

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
                    let pushCheck: Effect<Action> = isActive ? push(.becameActive, state: &state) : .none
                    return .merge(fleet(.scenePhaseChanged(isActive: isActive), state: &state), terminal, pushCheck)

                case .settingsButtonTapped:
                    state.isShowingSettings = true
                    return .none

                case .task:
                    return fleet(.task, state: &state)

                case .binding, .daemons, .detail, .fleet, .pairing, .push:
                    return .none
                }
            }
            .ifLet(\.$pairing, action: \.pairing) { Pairing() }
            .ifLet(\.detail, action: \.detail) { AgentDetail() }
            Reduce { state, _ in
                state.openPendingAgent()
                state.syncDetail()
                // The terminal opens and closes its socket as the agent starts
                // and stops, so that change is an action, not a state edit.
                guard let terminal = state.detail?.destination?.terminal, let agent = state.detail?.agent,
                      terminal.isAgentRunning == agent.isStopped else { return .none }
                return .send(.detail(.destination(.presented(.terminal(.agentRunningChanged(!agent.isStopped))))))
            }
        }
        .discardingPreviews(\.openPreviewFiles)
    }

    private func fleet(_ action: Fleet.Action, state: inout State) -> Effect<Action> {
        Fleet().reduce(into: &state.fleet, action: action).map(Action.fleet)
    }

    private func push(_ action: PushNotifications.Action, state: inout State) -> Effect<Action> {
        PushNotifications().reduce(into: &state.push, action: action).map(Action.push)
    }
}

extension AppFeature.State {
    /// The temporary files behind the open file preview, if any.
    var openPreviewFiles: [URL] { detail?.destination?.files?.preview?.temporaryFiles ?? [] }

    /// Opens a tapped notification's agent as soon as its daemon has
    /// reported it; gives up once the paired daemons are known and its
    /// daemon isn't one, or the daemon is connected and the agent is gone.
    mutating func openPendingAgent() {
        guard let ref = pendingAgent else { return }
        guard let session = fleet.sessions[id: ref.daemonID] else {
            if hasLoadedDaemons { pendingAgent = nil }
            return
        }
        if let agent = session.agents[id: ref.name] {
            pendingAgent = nil
            if detail?.ref != ref { detail = AgentDetail.State(daemon: session.daemon, agent: agent, connection: session.connection) }
        } else if session.connection.isConnected {
            pendingAgent = nil
        }
    }

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
