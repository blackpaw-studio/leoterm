import ComposableArchitecture
import Foundation
import LeoKit

/// The app root: the fleet of daemons, the Daemons screen, the selected
/// agent, the pairing sheet, Settings and push registration.
@Reducer
public struct AppFeature {
    @ObservableState
    public struct State: Equatable {
        /// The selected chat thread; exclusive with `detail` (both fill the
        /// secondary column).
        public var chat: ChatThread.State?
        public var chats = ChatList.State()
        public var daemons = Daemons.State()
        /// The selected agent. Selection, not presentation: on iPhone the
        /// split view collapses it onto the list's navigation stack.
        public var detail: AgentDetail.State?
        public var fleet = Fleet.State()
        public var isShowingChats = false
        public var isShowingDaemons = false
        public var isShowingSettings = false
        @Presents public var pairing: Pairing.State?
        public var push = PushNotifications.State()
        /// Whether the paired daemons have been read from disk yet.
        public var hasLoadedDaemons = false
        /// A tapped notification's agent, opened once the fleet has it.
        public var pendingAgent: AgentRef?
        /// A tapped chat notification's thread, opened once its daemon is known.
        public var pendingChat: AgentRef?

        public init() {}
    }

    public enum Action: BindableAction {
        case agentTapped(AgentRef)
        case binding(BindingAction<State>)
        case chat(ChatThread.Action)
        case chatNotificationAction(LeoChatNotificationResponse)
        case chatNotificationActionFinished
        /// A tapped chat notification (the app may have just launched for it).
        case chatNotificationOpened(AgentRef)
        case chatOpened(AgentRef)
        case chats(ChatList.Action)
        case chatsButtonTapped
        /// The Agents list showed its Chats entry: start keeping unread
        /// counts.
        case chatsEntryAppeared
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

    @Dependency(\.chatClient) var chatClient
    @Dependency(\.chatNotifier) var chatNotifier
    @Dependency(\.pairedDaemons) var pairedDaemons
    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        CombineReducers {
            BindingReducer()
            Scope(state: \.chats, action: \.chats) { ChatList() }
            Scope(state: \.fleet, action: \.fleet) { Fleet() }
            Scope(state: \.daemons, action: \.daemons) { Daemons() }
            Scope(state: \.push, action: \.push) { PushNotifications() }
            Reduce { state, action in
                switch action {
                case .agentTapped(let ref):
                    state.pendingAgent = nil
                    guard let session = state.fleet.sessions[id: ref.daemonID],
                          let agent = session.agents[id: ref.name] else { return .none }
                    state.chat = nil
                    if state.detail?.ref != ref {
                        state.detail = AgentDetail.State(daemon: session.daemon, agent: agent, connection: session.connection)
                    }
                    return .none

                case .chatNotificationAction(let response):
                    return perform(response)

                case .chatNotificationOpened(let ref):
                    state.pendingChat = ref
                    return .none

                case .chatOpened(let ref), .chats(.newChatPicked(let ref)), .chats(.rowTapped(let ref)):
                    state.openChat(ref)
                    return .none

                case .chatsButtonTapped:
                    state.isShowingChats = true
                    state.chats.isActive = true
                    return .send(.chats(.refresh(state.fleet.sessions.map(\.daemon))))

                case .chatsEntryAppeared:
                    guard !state.chats.isActive else { return .none }
                    state.chats.isActive = true
                    return .send(.chats(.refresh(state.fleet.sessions.map(\.daemon))))

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
                    // Chats load only once the user has seen their entry.
                    let daemon = state.chats.isActive ? state.fleet.sessions[id: id]?.daemon : nil
                    let refresh: Effect<Action> = daemon.map { .send(.chats(.refresh([$0]))) } ?? .none
                    return .merge(push(.daemonReconnected(id), state: &state), refresh, resyncChat(on: id, state: state))

                case .fleet(.sequenceGap(let id)):
                    return resyncChat(on: id, state: state)

                case .fleet(.eventReceived(let id, .chat(_, let event))):
                    let ref = AgentRef(daemonID: id, name: event.message.agent)
                    let toThread: Effect<Action> = state.chat?.ref == ref ? .send(.chat(.chatEvent(event))) : .none
                    return .concatenate(.send(.chats(.chatEvent(id, event, isOpen: state.isChatOnScreen(ref)))), toThread)

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

                case .detail(.chatButtonTapped):
                    if let ref = state.detail?.ref { state.openChat(ref) }
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

                case .binding, .chat, .chatNotificationActionFinished, .chats, .daemons, .detail, .fleet, .pairing, .push:
                    return .none
                }
            }
            .ifLet(\.$pairing, action: \.pairing) { Pairing() }
            .ifLet(\.detail, action: \.detail) { AgentDetail() }
            .ifLet(\.chat, action: \.chat) { ChatThread() }
            Reduce { state, _ in
                state.openPendingAgent()
                state.openPendingChat()
                state.syncDetail()
                state.syncChat()
                // The terminal opens and closes its socket as the agent starts
                // and stops, so that change is an action, not a state edit.
                guard let terminal = state.detail?.destination?.terminal, let agent = state.detail?.agent,
                      terminal.isAgentRunning == agent.isStopped else { return .none }
                return .send(.detail(.destination(.presented(.terminal(.agentRunningChanged(!agent.isStopped))))))
            }
        }
        .discardingPreviews(\.openPreviewFiles)
    }

    /// Events from `daemonID` may have been lost (a reconnect or a sequence
    /// gap): the open thread on it reloads.
    private func resyncChat(on daemonID: DaemonSession.ID, state: State) -> Effect<Action> {
        state.chat?.daemon.id == daemonID ? .send(.chat(.resync)) : .none
    }

    private func fleet(_ action: Fleet.Action, state: inout State) -> Effect<Action> {
        Fleet().reduce(into: &state.fleet, action: action).map(Action.fleet)
    }

    /// Replies or answers from a notification action. The app may have
    /// launched in the background for it, so the daemon comes from disk.
    private func perform(_ response: LeoChatNotificationResponse) -> Effect<Action> {
        let target: LeoPushTarget = switch response {
        case .reply(let target, _, _), .answer(let target, _, _): target
        }
        return .run { [chatClient, chatNotifier, pairedDaemons, secrets] send in
            do {
                guard let daemon = try pairedDaemons.load().first(where: { $0.id == target.daemonID }) else {
                    throw ChatConnectionError.missingCredentials
                }
                let connection = try secrets.connection(for: daemon)
                switch response {
                case .reply(_, let text, let replyTo):
                    _ = try await chatClient.send(connection, target.agent, LeoChatDraft(text: text, replyTo: replyTo))
                case .answer(_, let messageID, let value):
                    _ = try await chatClient.answer(connection, target.agent, messageID, .choice(value))
                }
            } catch {
                await chatNotifier.actionFailed(target.agent, error.localizedDescription)
            }
            await send(.chatNotificationActionFinished)
        }
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

    /// Whether `ref`'s thread is the one on screen (its banners are
    /// suppressed and its messages count as read).
    public func isChatOnScreen(_ ref: AgentRef) -> Bool {
        chat?.ref == ref && chat?.isOnScreen == true
    }

    /// Shows `ref`'s thread in place of any agent detail.
    mutating func openChat(_ ref: AgentRef) {
        guard let session = fleet.sessions[id: ref.daemonID] else { return }
        pendingChat = nil
        pendingAgent = nil
        detail = nil
        chats.threads[ref.daemonID]?[id: ref.name]?.unread = 0
        guard chat?.ref != ref else { return }
        chat = ChatThread.State(daemon: session.daemon, agent: ref.name, live: session.agents[id: ref.name])
    }

    /// Opens a tapped chat notification's thread once its daemon is known;
    /// gives up when the paired daemons are loaded and it isn't one.
    mutating func openPendingChat() {
        guard let ref = pendingChat else { return }
        if fleet.sessions[id: ref.daemonID] != nil {
            openChat(ref)
        } else if hasLoadedDaemons {
            pendingChat = nil
        }
    }

    /// Keeps the open thread's agent and daemon in step with the fleet.
    mutating func syncChat() {
        guard let ref = chat?.ref, let session = fleet.sessions[id: ref.daemonID] else { return }
        let agent = session.agents[id: ref.name]
        if chat?.agent != agent { chat?.agent = agent }
        if chat?.daemon != session.daemon { chat?.daemon = session.daemon }
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
