import ComposableArchitecture
import Foundation
import LeoKit

extension AgentRef {
    var leoAgentID: LeoAgentID { LeoAgentID(host: .remote(daemonID), name: name) }
}

/// One row of the Chats list.
public struct ChatRow: Equatable, Identifiable, Sendable {
    public enum Section: Int, Comparable, Sendable {
        case pinned, recent, running

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let ref: AgentRef
    /// What the user sees for this agent; `ref.name` stays the identifier.
    public var displayName: String { agent?.displayName ?? ref.name }
    /// Set only when more than one daemon is paired.
    public let daemonName: String?
    public let lastMessage: LeoChatMessage?
    public let unread: Int
    public let isRunning: Bool
    public let section: Section
    /// The fleet's record of this thread's agent; nil when it is not in the fleet.
    public let agent: Agent?

    public var id: AgentRef { ref }

    public var bucket: ChatBucket? { agent.flatMap { ChatBucket($0.priority) } }

    /// The orange lead-in on the preview line when the agent wants something.
    public var previewPrefix: ChatPreviewPrefix? {
        switch agent?.priority {
        case .needsInput: .asks
        case .errored: .error
        default: nil
        }
    }
}

extension LeoInboxItem {
    /// The agent this item routes to; nil for a host that is not a paired daemon.
    public var agentRef: AgentRef? {
        guard case .remote(let daemonID) = id.host else { return nil }
        return AgentRef(daemonID: daemonID, name: id.name)
    }
}

/// Where an agent was looked at, so its seen mark can be set (and synced).
public struct SeenTarget: Equatable, Sendable {
    public let daemonID: String
    public let agent: String
    public let at: Date?
    public let revision: Int?
    public let bootID: String?

    public init(daemonID: String, agent: String, at: Date? = nil, revision: Int? = nil, bootID: String? = nil) {
        self.daemonID = daemonID
        self.agent = agent
        self.at = at
        self.revision = revision
        self.bootID = bootID
    }

    var leoAgentID: LeoAgentID { LeoAgentID(host: .remote(daemonID), name: agent) }
}

/// The inbox's status groups; nil on a row means no dot.
public enum ChatBucket: Int, Comparable, Sendable {
    case needsYou, working, done

    init?(_ priority: AgentPriority) {
        switch priority {
        case .needsInput: self = .needsYou
        case .working: self = .working
        case .finished, .errored: self = .done
        case .idle, .stopped: return nil
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ChatPreviewPrefix: Equatable, Sendable {
    case asks, error
}

/// The inbox's filter chips.
public enum ChatFilter: Equatable, CaseIterable, Sendable {
    case all, needsYou, working, done

    func includes(_ row: ChatRow) -> Bool {
        switch self {
        case .all: true
        case .needsYou: row.bucket == .needsYou
        case .working: row.bucket == .working
        case .done: row.bucket == .done
        }
    }
}

/// How many rows the chips with counts show.
public struct ChatCounts: Equatable, Sendable {
    public var needsYou: Int
    public var working: Int

    public init(needsYou: Int, working: Int) {
        self.needsYou = needsYou
        self.working = working
    }
}

/// The Chats list: every daemon's threads plus running agents that have
/// none yet, and the "New chat" picker. Selecting a row is the parent's.
@Reducer
public struct ChatList {
    public static let assistant = "assistant"

    @ObservableState
    public struct State: Equatable {
        /// Each daemon's last load failure, by daemon id.
        public var errors: [String: String] = [:]
        /// Whether threads are being kept fresh (the Chats entry has shown).
        public var isActive = false
        public var isShowingNewChat = false
        /// The selected chip; nil until the app has decided a default, and
        /// read as All meanwhile.
        public var filter: ChatFilter?
        public var searchText = ""
        /// Each daemon's threads, by daemon id.
        public var threads: [String: IdentifiedArrayOf<LeoChatThread>] = [:]
        /// Unread agent messages: seeded from each load, bumped by live
        /// events, cleared on read. A daemon id is its `LeoHostID.remote` name.
        public var unreadCounts = LeoChatUnreadCounts()
        /// Open chat asks (ask and permission rows) of every host.
        public var openAsks = LeoOpenAsks()
        /// Which finished items were already looked at, per host.
        public var seen = LeoInboxSeenState()
        /// The daemons last refreshed, by id: the inbox acts on them (answers, seen marks).
        var daemons: [String: PairedDaemon] = [:]
        /// Agents whose inline answer is in flight: their card is disabled.
        public var answering: Set<LeoAgentID> = []
        /// The daemon's reason an inline answer failed, by agent.
        public var askErrors: [LeoAgentID: String] = [:]
        /// Chat events that arrived while a host's open asks were loading;
        /// applied again once the load answers.
        var eventsDuringSeed: [String: [LeoChatEvent]] = [:]

        public init() {}

        /// A disconnected host's open asks go; they come back with the next load.
        mutating func dropOpenAsks(ofHosts hosts: [String]) {
            for daemonID in hosts where !openAsks.threads(host: .remote(daemonID)).isEmpty {
                openAsks.disconnect(host: .remote(daemonID))
            }
        }

        public var unreadTotal: Int {
            threads.reduce(0) { total, daemon in
                total + daemon.value.reduce(0) { $0 + unreadCounts[LeoAgentID(host: .remote(daemon.key), name: $1.agent)] }
            }
        }
    }

    public enum Action: BindableAction {
        /// The daemon's `agent_seen` event: someone looked at the agent.
        case agentSeen(String, agent: String, seenAt: Date)
        /// The user answered an open ask from the inbox.
        case askAnswered(daemonID: String, agent: String, messageID: String, LeoChatAnswer)
        case askAnswerResponse(daemonID: String, agent: String, Result<LeoChatMessage?, any Error>)
        case binding(BindingAction<State>)
        case clearFinishedTapped([LeoInboxItem])
        /// "Dismiss" on a blocked card: hides it until it changes; answers nothing.
        case dismissTapped(LeoInboxItem)
        case markSeen([SeenTarget])
        case openAsksResponse(String, Result<[LeoChatMessage]?, any Error>)
        case seenResponse(String, Result<[String: Date]?, any Error>)
        case seenRestored(LeoInboxSeenState)
        case chatEvent(String, LeoChatEvent, isOpen: Bool)
        case filterPicked(ChatFilter)
        case newChatButtonTapped
        case newChatPicked(AgentRef)
        case refresh([PairedDaemon])
        case rowTapped(AgentRef)
        case threadRead(AgentRef)
        case threadsResponse(String, Result<[LeoChatThread], any Error>)
    }

    @Dependency(\.chatClient) var chatClient
    @Dependency(\.date.now) var now
    @Dependency(\.inboxSeenStore) var inboxSeenStore
    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding, .rowTapped:
                return .none

            case .agentSeen(let daemonID, let agent, let seenAt):
                state.seen.apply(host: .remote(daemonID), agent: agent, seenAt: seenAt)
                return .none

            case .askAnswered(let daemonID, let agent, let messageID, let answer):
                let answerer = LeoAgentID(host: .remote(daemonID), name: agent)
                // One answer at a time per agent: a second tap would send it twice.
                guard let daemon = state.daemons[daemonID], state.answering.insert(answerer).inserted else { return .none }
                state.askErrors[answerer] = nil
                return .run { [chatClient, secrets] send in
                    await send(.askAnswerResponse(daemonID: daemonID, agent: agent, Result {
                        let connection = try secrets.connection(for: daemon)
                        if let answers = answer.answers {
                            return try await chatClient.answerQuestions(connection, agent, messageID, answers)
                        }
                        return try await chatClient.answer(connection, agent, messageID, answer)
                    }))
                }

            case .askAnswerResponse(let daemonID, let agent, .success(let message)):
                state.answering.remove(LeoAgentID(host: .remote(daemonID), name: agent))
                if let message { state.openAsks.apply(host: .remote(daemonID), event: .updated(message)) }
                return .none

            case .askAnswerResponse(let daemonID, let agent, .failure(let error)):
                state.answering.remove(LeoAgentID(host: .remote(daemonID), name: agent))
                // Settled elsewhere (409): the card is stale, so reload the open set.
                if error as? LeoChatAnswerError == .settled { return loadOpenAsks(daemonID, state: &state) }
                state.askErrors[LeoAgentID(host: .remote(daemonID), name: agent)] = error.localizedDescription
                return .none

            case .chatEvent(let daemonID, let event, let isOpen):
                apply(event, daemonID: daemonID, isOpen: isOpen, state: &state)
                state.openAsks.apply(host: .remote(daemonID), event: event)
                if state.eventsDuringSeed[daemonID] != nil { state.eventsDuringSeed[daemonID]?.append(event) }
                return .none

            case .clearFinishedTapped(let items):
                let targets = items.filter { !$0.isBlocked }.compactMap { item -> SeenTarget? in
                    guard case .remote(let daemonID) = item.id.host else { return nil }
                    return SeenTarget(daemonID: daemonID, agent: item.id.name, at: item.at, revision: item.revision, bootID: item.bootID)
                }
                return markSeen(targets, state: &state)

            case .dismissTapped(let item):
                guard item.isBlocked, let target = Self.dismissTarget(item) else { return .none }
                return markSeen([target], state: &state)

            case .markSeen(let targets):
                return markSeen(targets, state: &state)

            case .openAsksResponse(let daemonID, let result):
                let events = state.eventsDuringSeed.removeValue(forKey: daemonID) ?? []
                switch result {
                case .success(let messages?):
                    state.openAsks.seed(host: .remote(daemonID), messages: messages, complete: true)
                case .success(nil):
                    // No open-asks route (older daemon): what was kept may be answered by now.
                    // Start over from the threads' last messages.
                    state.openAsks.disconnect(host: .remote(daemonID))
                    let lastMessages = (state.threads[daemonID] ?? []).compactMap(\.lastMessage)
                    state.openAsks.seed(host: .remote(daemonID), messages: lastMessages, complete: false)
                    state.openAsks.markLoaded(host: .remote(daemonID))
                case .failure:
                    break
                }
                if case .success = result { for event in events { state.openAsks.apply(host: .remote(daemonID), event: event) } }
                return .none

            case .seenResponse(let daemonID, .success(let seen)):
                state.seen.seed(host: .remote(daemonID), seen: seen)
                inboxSeenStore.save(state.seen)
                return .none

            case .seenResponse:
                // A failed load leaves the host as it was; the next refresh retries.
                return .none

            case .seenRestored(let restored):
                if state.seen.hosts.isEmpty { state.seen = restored }
                return .none

            case .filterPicked(let filter):
                state.filter = filter
                return .none

            case .newChatButtonTapped:
                state.isShowingNewChat = true
                return .none

            case .newChatPicked:
                state.isShowingNewChat = false
                return .none

            case .refresh(let daemons):
                for daemon in daemons { state.daemons[daemon.id] = daemon }
                let loads = daemons.map { daemon -> Effect<Action> in
                    .merge(
                        .run { [chatClient, secrets] send in
                            await send(.threadsResponse(daemon.id, Result { try await chatClient.threads(try secrets.connection(for: daemon)) }))
                        },
                        loadOpenAsks(daemon.id, state: &state),
                        .run { [chatClient, secrets] send in
                            await send(.seenResponse(daemon.id, Result { try await chatClient.seen(try secrets.connection(for: daemon)) }))
                        }
                    )
                }
                return .merge(.run { [inboxSeenStore] send in await send(.seenRestored(inboxSeenStore.load())) }, .merge(loads))

            case .threadRead(let ref):
                state.unreadCounts = state.unreadCounts.clearing(ref.leoAgentID)
                return .none

            case .threadsResponse(let daemonID, .success(let threads)):
                state.errors[daemonID] = nil
                state.threads[daemonID] = IdentifiedArray(threads, uniquingIDsWith: { $1 })
                state.unreadCounts = state.unreadCounts.seeding(threads, host: .remote(daemonID))
                // The threads' last messages show an ask on a daemon without the open-asks route.
                state.openAsks.seed(host: .remote(daemonID), messages: threads.compactMap(\.lastMessage), complete: false)
                return .none

            case .threadsResponse(let daemonID, .failure(let error)):
                state.errors[daemonID] = error.localizedDescription
                return .none
            }
        }
    }

    /// Loads one host's open asks, remembering chat events that arrive meanwhile.
    private func loadOpenAsks(_ daemonID: String, state: inout State) -> Effect<Action> {
        guard let daemon = state.daemons[daemonID] else { return .none }
        state.eventsDuringSeed[daemonID] = state.eventsDuringSeed[daemonID] ?? []
        return .run { [chatClient, secrets] send in
            await send(.openAsksResponse(daemonID, Result { try await chatClient.openAsks(try secrets.connection(for: daemon)) }))
        }
    }

    /// What dismissing `item` marks seen: its agent, at least as far as the item's last change.
    static func dismissTarget(_ item: LeoInboxItem) -> SeenTarget? {
        guard case .remote(let daemonID) = item.id.host else { return nil }
        return SeenTarget(daemonID: daemonID, agent: item.id.name, at: item.dismissAt ?? item.at, revision: item.revision, bootID: item.bootID)
    }

    private func markSeen(_ targets: [SeenTarget], state: inout State) -> Effect<Action> {
        Self.markSeen(targets, state: &state, now: { now }, store: inboxSeenStore, chatClient: chatClient, secrets: secrets)
    }

    /// Marks agents looked at: locally (persisted), then on every daemon that
    /// syncs it. A host whose seen state has not loaded yet is skipped.
    static func markSeen(
        _ targets: [SeenTarget], state: inout State, now: () -> Date, store: InboxSeenStoreClient, chatClient: ChatClient,
        secrets: SecretsClient
    ) -> Effect<Action> {
        let known = targets.filter { state.seen.hosts[.remote($0.daemonID)] != nil }
        guard !known.isEmpty else { return .none }
        let stamp = now()
        for target in known {
            state.seen.markSeen(target.leoAgentID, at: target.at, revision: target.revision, bootID: target.bootID, now: stamp)
        }
        store.save(state.seen)
        let synced = Dictionary(grouping: known, by: \.daemonID).compactMap { daemonID, group -> (PairedDaemon, [String])? in
            guard case .synced = state.seen.hosts[.remote(daemonID)], let daemon = state.daemons[daemonID] else { return nil }
            return (daemon, group.map(\.agent))
        }
        return .merge(synced.map { daemon, agents in
            .run { send in
                // Best effort: the local mark already hides the item; the next load re-syncs.
                guard let seen = try? await chatClient.markSeen(try secrets.connection(for: daemon), agents) else { return }
                await send(.seenResponse(daemon.id, .success(seen)))
            }
        })
    }

    private func apply(_ event: LeoChatEvent, daemonID: String, isOpen: Bool, state: inout State) {
        let message = event.message
        var threads = state.threads[daemonID] ?? []
        var thread = threads[id: message.agent] ?? LeoChatThread(agent: message.agent)
        switch event {
        case .message:
            if let last = thread.lastMessage, (last.ts, last.id) > (message.ts, message.id) { return }
            thread.lastMessage = message
            state.unreadCounts = state.unreadCounts.receiving(event, host: .remote(daemonID), isOnScreen: isOpen)
        case .updated:
            guard thread.lastMessage?.id == message.id else { return }
            thread.lastMessage = message
        }
        threads[id: message.agent] = thread
        state.threads[daemonID] = threads
    }

    /// Every thread plus running agents with no thread yet, ordered for the
    /// inbox: Needs you, then Working, then the rest; newest message first
    /// within each, the assistant first in its own group.
    public static func rows(threads: [String: IdentifiedArrayOf<LeoChatThread>], unread: LeoChatUnreadCounts = LeoChatUnreadCounts(), sessions: IdentifiedArrayOf<DaemonSession>) -> [ChatRow] {
        let isMultiDaemon = sessions.count > 1
        let rows = sessions.flatMap { session -> [ChatRow] in
            let daemonThreads = threads[session.id] ?? []
            let daemonName = isMultiDaemon ? session.daemon.name : nil
            let threadRows = daemonThreads.map { thread in
                let agent = session.agents[id: thread.agent]
                return ChatRow(
                    ref: AgentRef(daemonID: session.id, name: thread.agent), daemonName: daemonName, lastMessage: thread.lastMessage,
                    unread: unread[LeoAgentID(host: .remote(session.id), name: thread.agent)], isRunning: agent.map { !$0.isStopped } ?? false,
                    section: thread.isPinned ? .pinned : .recent, agent: agent
                )
            }
            let runningRows = session.agents
                .filter { !$0.isStopped && daemonThreads[id: $0.name] == nil }
                .map { ChatRow(ref: AgentRef(daemonID: session.id, name: $0.name), daemonName: daemonName, lastMessage: nil, unread: 0, isRunning: true, section: .running, agent: $0) }
            return threadRows + runningRows
        }
        return rows.sorted(by: isOrderedBefore)
    }

    /// The needs-you inbox across every connected machine; a disconnected
    /// one drops out, and stopped agents never contribute.
    public static func inbox(sessions: IdentifiedArrayOf<DaemonSession>, openAsks: LeoOpenAsks, seen: LeoInboxSeenState) -> LeoInbox {
        let agents = sessions.flatMap { session in session.agents.map { inboxAgent($0, session: session) } }
        return LeoInbox.derive(agents: agents, openAsks: openAsks.threads, seen: seen)
    }

    /// The inbox's view of one agent; a stopped one contributes nothing (LeoKit).
    static func inboxAgent(_ agent: Agent, session: DaemonSession) -> LeoInboxAgent {
        LeoInboxAgent(
            id: LeoAgentID(host: .remote(session.id), name: agent.name), name: agent.displayName, machine: session.daemon.name,
            signal: agent.attention, bootID: session.bootID, isStale: !session.connection.isConnected, isStopped: agent.isStopped,
            brief: agent.brief
        )
    }

    /// The rows the selected chip and search field leave.
    public static func visible(_ rows: [ChatRow], filter: ChatFilter?, search: String) -> [ChatRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            (filter ?? .all).includes(row) && (query.isEmpty || matches(row, query))
        }
    }

    public static func counts(_ rows: [ChatRow]) -> ChatCounts {
        ChatCounts(needsYou: rows.count { $0.bucket == .needsYou }, working: rows.count { $0.bucket == .working })
    }

    private static func matches(_ row: ChatRow, _ query: String) -> Bool {
        let message = row.lastMessage
        return [row.ref.name, row.displayName, message?.text, message?.transcript].contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    /// Needs you, then Working, then everything else (done, idle, unknown).
    private static func rank(_ row: ChatRow) -> Int {
        switch row.bucket {
        case .needsYou: 0
        case .working: 1
        case .done, nil: 2
        }
    }

    private static func isOrderedBefore(_ lhs: ChatRow, _ rhs: ChatRow) -> Bool {
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        let (left, right) = (lhs.ref.name == assistant, rhs.ref.name == assistant)
        if left != right { return left }
        let (leftDate, rightDate) = (lhs.lastMessage?.ts ?? .distantPast, rhs.lastMessage?.ts ?? .distantPast)
        if leftDate != rightDate { return leftDate > rightDate }
        return (lhs.displayName, lhs.ref.name, lhs.daemonName ?? "") < (rhs.displayName, rhs.ref.name, rhs.daemonName ?? "")
    }
}
