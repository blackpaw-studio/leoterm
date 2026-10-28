import ComposableArchitecture
import Foundation
import LeoKit

/// The app root: the fleet of daemons, the Daemons screen, the selected
/// agent, the pairing sheet, Settings and push registration.
@Reducer
public struct AppFeature {
    @ObservableState
    public struct State: Equatable {
        /// The selected chat thread. Without a `detail` it fills the secondary
        /// column; with one (the same agent's, opened from its detail screen)
        /// it sits over the detail, which Back returns to.
        public var chat: ChatThread.State?
        public var chats = ChatList.State()
        public var daemons = Daemons.State()
        /// The selected agent. Selection, not presentation: on iPhone the
        /// split view collapses it onto the list's navigation stack. Stays
        /// set under `chat` when the chat was opened from it.
        public var detail: AgentDetail.State?
        /// The Appearance sheet, opened by a long press on an agent row.
        @Presents public var appearance: AgentAppearance.State?
        public var fleet = Fleet.State()
        /// The open move, copy or duplicate flow (B-324); its prompts and
        /// alerts are shown over everything.
        @Presents public var move: AgentMove.State?
        /// Each daemon's move hosts, read when it connects with `agent_move`.
        public var moveDestinations: [DaemonSession.ID: LeoMoveDestinations] = [:]
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
        /// Unsent answers of questions cards in threads that aren't open, by
        /// agent then message id. A thread's state is replaced when another
        /// opens, so its drafts wait here; they leave when their thread
        /// reopens and the card turns out settled (`ChatThread.State.merge`).
        public var parkedQuestionsDrafts: [AgentRef: [String: LeoChatQuestionsDraft]] = [:]

        public init() {}
    }

    public enum Action: BindableAction {
        case agentTapped(AgentRef)
        case appearance(PresentationAction<AgentAppearance.Action>)
        /// Long press > Appearance. Ignored for a daemon that doesn't
        /// advertise `agent_appearance`.
        case appearanceRequested(AgentRef)
        case binding(BindingAction<State>)
        case chat(ChatThread.Action)
        case chatNotificationAction(LeoChatNotificationResponse)
        case chatNotificationActionFinished
        /// A tapped chat notification (the app may have just launched for it).
        case chatNotificationOpened(AgentRef)
        case chatOpened(AgentRef)
        /// The user popped a chat opened from an agent's detail back to it
        /// (the detail stays selected).
        case chatPopped
        case chats(ChatList.Action)
        case chatsButtonTapped
        /// The Agents list showed its Chats entry: start keeping unread
        /// counts.
        case chatsEntryAppeared
        case daemons(Daemons.Action)
        case daemonsButtonTapped
        case detail(AgentDetail.Action)
        case fleet(Fleet.Action)
        case move(PresentationAction<AgentMove.Action>)
        /// Move To, Copy To or Duplicate on an agent: opens the flow. Ignored
        /// for a daemon without `agent_move` and for an agent that moved away.
        case moveRequested(AgentRef, AgentMove.Intent)
        case moveHostsLoaded(DaemonSession.ID, LeoMoveDestinations)
        /// A tapped notification (the app may have just launched for it).
        case notificationOpened(AgentRef)
        case pairButtonTapped
        case pairing(PresentationAction<Pairing.Action>)
        case push(PushNotifications.Action)
        case scenePhaseChanged(isActive: Bool)
        /// The user popped the agent or chat back to the list (iPhone):
        /// nothing is selected any more.
        case secondaryPopped
        case settingsButtonTapped
        /// Settings > Stats style.
        case statsStyleSelected(LeoStatsStyle)
        case task
    }

    @Dependency(\.chatClient) var chatClient
    @Dependency(\.chatNotifier) var chatNotifier
    @Dependency(\.daemonClient) var daemonClient
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
                    state.parkChatDrafts()
                    state.chat = nil
                    if state.detail?.ref != ref {
                        state.detail = AgentDetail.State(daemon: session.daemon, agent: agent, connection: session.connection)
                    }
                    return .none

                case .appearanceRequested(let ref):
                    guard let session = state.fleet.sessions[id: ref.daemonID], session.supportsAppearance,
                          let agent = session.agents[id: ref.name] else { return .none }
                    state.appearance = AgentAppearance.State(daemon: session.daemon, agentName: ref.name, appearance: agent.appearance)
                    return .none

                case .chatNotificationAction(let response):
                    return perform(response)

                case .chatNotificationOpened(let ref):
                    state.pendingChat = ref
                    return .none

                case .chatOpened(let ref), .chats(.newChatPicked(let ref)), .chats(.rowTapped(let ref)):
                    state.openChat(ref)
                    return .none

                case .chatPopped:
                    state.parkChatDrafts()
                    state.chat = nil
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
                    if state.appearance?.daemon.id == id { state.appearance = nil }
                    if state.move?.daemon.id == id { state.move = nil }
                    state.moveDestinations[id] = nil
                    if state.daemons.machine?.id == id { state.daemons.machine = nil }
                    guard let daemon = state.fleet.sessions[id: id]?.daemon else { return fleet(.daemonRemoved(id), state: &state) }
                    // Push reads the daemon's token before the removal deletes it.
                    return .concatenate(push(.daemonForgotten(daemon), state: &state), fleet(.daemonRemoved(id), state: &state))

                case .daemons(.delegate(.openMachine(let id))):
                    guard let session = state.fleet.sessions[id: id] else { return .none }
                    state.daemons.machine = MachineSettings.State(link: MachineLink(session: session))
                    return .none

                case .daemons(.delegate(.retry(let id))):
                    return fleet(.retryButtonTapped(id), state: &state)

                case .daemons(.delegate(.visibilityChanged(let isVisible))):
                    return fleet(.statsVisibilityChanged(isVisible), state: &state)

                case .statsStyleSelected(let style):
                    return fleet(.statsStyleChanged(style), state: &state)

                case .daemonsButtonTapped:
                    state.isShowingDaemons = true
                    return .none

                case .fleet(.connected(let id, _, _, _)):
                    // Chats load only once the user has seen their entry.
                    let daemon = state.chats.isActive ? state.fleet.sessions[id: id]?.daemon : nil
                    let refresh: Effect<Action> = daemon.map { .send(.chats(.refresh([$0]))) } ?? .none
                    return .merge(
                        push(.daemonReconnected(id), state: &state), refresh, resyncChat(on: id, state: state), loadMoveHosts(id, state: state)
                    )

                case .move(.presented(.delegate(.completed))):
                    // The flow stays up while it has an alert to show.
                    let id = state.move?.daemon.id
                    if state.move?.alert == nil { state.move = nil }
                    return id.map { fleet(.refreshRequested($0), state: &state) } ?? .none

                case .move(.presented(.delegate(.dismissed))):
                    state.move = nil
                    return .none

                case .moveHostsLoaded(let id, let destinations):
                    state.moveDestinations[id] = destinations
                    return .none

                case .moveRequested(let ref, let intent):
                    state.openMove(ref, intent)
                    return .none

                case .detail(.moveRequested(let intent)):
                    if let ref = state.detail?.ref { state.openMove(ref, intent) }
                    return .none

                case .fleet(.sequenceGap(let id)):
                    return resyncChat(on: id, state: state)

                case .fleet(.eventReceived(let id, .chat(_, let event))):
                    let ref = AgentRef(daemonID: id, name: event.message.agent)
                    let toThread: Effect<Action> = state.chat?.ref == ref ? .send(.chat(.chatEvent(event))) : .none
                    return .concatenate(.send(.chats(.chatEvent(id, event, isOpen: state.isChatOnScreen(ref)))), toThread)

                case .fleet(.daemonsLoaded(let daemons)):
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
                    if let ref = state.detail?.ref { state.openChat(ref, overDetail: true) }
                    return .none

                case .scenePhaseChanged(let isActive):
                    let terminal: Effect<Action> = state.detail?.destination?.terminal == nil
                        ? .none
                        : .send(.detail(.destination(.presented(.terminal(.scenePhaseChanged(isActive: isActive))))))
                    let pushCheck: Effect<Action> = isActive ? push(.becameActive, state: &state) : .none
                    let settings: Effect<Action> = state.daemons.machine == nil
                        ? .none
                        : .send(.daemons(.machine(.presented(.scenePhaseChanged(isActive: isActive)))))
                    return .merge(fleet(.scenePhaseChanged(isActive: isActive), state: &state), terminal, pushCheck, settings)

                case .secondaryPopped:
                    state.parkChatDrafts()
                    state.chat = nil
                    state.detail = nil
                    return .none

                case .settingsButtonTapped:
                    state.isShowingSettings = true
                    return .none

                case .task:
                    return fleet(.task, state: &state)

                case .binding(\.isShowingDaemons):
                    // A pop that skips the Machines list (the back button's
                    // menu, a stack reset) never reports the machine above it
                    // closed; left set, the next tap on its row presents
                    // nothing because the item is unchanged.
                    if !state.isShowingDaemons { state.daemons.machine = nil }
                    return .none

                case .appearance, .binding, .chat, .chatNotificationActionFinished, .chats, .daemons, .detail, .fleet, .move, .pairing, .push:
                    return .none
                }
            }
            .ifLet(\.$pairing, action: \.pairing) { Pairing() }
            .ifLet(\.$appearance, action: \.appearance) { AgentAppearance() }
            .ifLet(\.$move, action: \.move) { AgentMove() }
            .ifLet(\.detail, action: \.detail) { AgentDetail() }
            .ifLet(\.chat, action: \.chat) { ChatThread() }
            Reduce { state, _ in
                state.openPendingAgent()
                state.openPendingChat()
                state.syncDetail()
                state.syncAppearance()
                state.syncChat()
                let machine = state.machineLinkUpdate()
                // The terminal opens and closes its socket as the agent starts
                // and stops, so that change is an action, not a state edit.
                guard let terminal = state.detail?.destination?.terminal, let agent = state.detail?.agent,
                      terminal.isAgentRunning == agent.isStopped else { return machine }
                return .merge(machine, .send(.detail(.destination(.presented(.terminal(.agentRunningChanged(!agent.isStopped)))))))
            }
        }
    }

    /// Events from `daemonID` may have been lost (a reconnect or a sequence
    /// gap): the open thread on it reloads.
    private func resyncChat(on daemonID: DaemonSession.ID, state: State) -> Effect<Action> {
        state.chat?.daemon.id == daemonID ? .send(.chat(.resync)) : .none
    }

    /// Reads a connected daemon's move hosts, when it can move agents at all.
    private func loadMoveHosts(_ id: DaemonSession.ID, state: State) -> Effect<Action> {
        guard let session = state.fleet.sessions[id: id], session.supportsMove else { return .none }
        let (daemon, daemonClient, secrets) = (session.daemon, daemonClient, secrets)
        return .run { send in
            guard let saved = try? secrets.load(daemon.id) else {
                await send(.moveHostsLoaded(id, .unavailable))
                return
            }
            await send(.moveHostsLoaded(id, await daemonClient.moveHosts(DaemonConnection(daemon: daemon, secrets: saved))))
        }
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
            } catch LeoChatAnswerError.settled {
                // Answered elsewhere or expired: the notification was stale.
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
    /// What `daemonID`'s agents' Move menus offer.
    public func moveAvailability(for daemonID: DaemonSession.ID) -> MoveAvailability {
        MoveAvailability(supportsMove: fleet.sessions[id: daemonID]?.supportsMove == true, destinations: moveDestinations[daemonID])
    }

    /// Opens the move flow for `ref`, unless its daemon can't move agents or
    /// the agent already lives elsewhere.
    mutating func openMove(_ ref: AgentRef, _ intent: AgentMove.Intent) {
        guard let session = fleet.sessions[id: ref.daemonID], session.supportsMove,
              let agent = session.agents[id: ref.name], agent.canMove else { return }
        move = AgentMove.State(daemon: session.daemon, agentName: ref.name, intent: intent)
    }

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
            parkChatDrafts()
            chat = nil
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

    /// Shows `ref`'s thread in place of any agent detail, or over it when it
    /// was opened from that detail.
    mutating func openChat(_ ref: AgentRef, overDetail: Bool = false) {
        guard let session = fleet.sessions[id: ref.daemonID] else { return }
        pendingChat = nil
        pendingAgent = nil
        // Re-opening the chat already shown over its detail leaves that detail be.
        let isShownOverItsDetail = chat?.ref == ref && detail?.ref == ref
        if !overDetail, !isShownOverItsDetail { detail = nil }
        chats.unreadCounts = chats.unreadCounts.clearing(ref.leoAgentID)
        guard chat?.ref != ref else { return }
        parkChatDrafts()
        var thread = ChatThread.State(daemon: session.daemon, agent: ref.name, live: session.agents[id: ref.name])
        thread.questionsDrafts = parkedQuestionsDrafts.removeValue(forKey: ref) ?? [:]
        chat = thread
    }

    /// Sets the open thread's unsent questions answers aside before it is replaced.
    mutating func parkChatDrafts() {
        guard let thread = chat, !thread.questionsDrafts.isEmpty else { return }
        parkedQuestionsDrafts[thread.ref] = thread.questionsDrafts
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

    /// The open machine's settings follow the fleet through an action, so the
    /// settings can tell a pane that its machine reconnected.
    func machineLinkUpdate() -> Effect<AppFeature.Action> {
        guard let machine = daemons.machine, let session = fleet.sessions[id: machine.id] else { return .none }
        let link = MachineLink(session: session)
        return link == machine.link ? .none : .send(.daemons(.machine(.presented(.linkUpdated(link)))))
    }

    /// Keeps the open detail in step with the live fleet.
    mutating func syncDetail() {
        guard let ref = detail?.ref, let session = fleet.sessions[id: ref.daemonID] else { return }
        let agent = session.agents[id: ref.name]
        if detail?.agent != agent { detail?.agent = agent }
        if detail?.connection != session.connection { detail?.connection = session.connection }
        if detail?.daemon != session.daemon { detail?.daemon = session.daemon }
        let moves = moveAvailability(for: ref.daemonID)
        if detail?.moves != moves { detail?.moves = moves }
    }

    /// Keeps the open Appearance sheet in step with the live fleet.
    mutating func syncAppearance() {
        guard let sheet = appearance, let session = fleet.sessions[id: sheet.daemon.id] else { return }
        let agent = session.agents[id: sheet.agentName]
        // Only a change in the fleet's value: its stale one must not undo a write's answer.
        if let agent, agent.appearance != sheet.fleetAppearance {
            appearance?.fleetAppearance = agent.appearance
            appearance?.receive(agent.appearance)
        }
        if sheet.daemon != session.daemon { appearance?.daemon = session.daemon }
    }
}
