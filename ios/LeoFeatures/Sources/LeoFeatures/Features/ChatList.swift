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
    /// Set only when more than one daemon is paired.
    public let daemonName: String?
    public let lastMessage: LeoChatMessage?
    public let unread: Int
    public let isRunning: Bool
    public let section: Section

    public var id: AgentRef { ref }
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
        /// Each daemon's threads, by daemon id.
        public var threads: [String: IdentifiedArrayOf<LeoChatThread>] = [:]
        /// Unread agent messages: seeded from each load, bumped by live
        /// events, cleared on read. A daemon id is its `LeoHostID.remote` name.
        public var unreadCounts = LeoChatUnreadCounts()

        public init() {}

        public var unreadTotal: Int {
            threads.reduce(0) { total, daemon in
                total + daemon.value.reduce(0) { $0 + unreadCounts[LeoAgentID(host: .remote(daemon.key), name: $1.agent)] }
            }
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case chatEvent(String, LeoChatEvent, isOpen: Bool)
        case newChatButtonTapped
        case newChatPicked(AgentRef)
        case refresh([PairedDaemon])
        case rowTapped(AgentRef)
        case threadRead(AgentRef)
        case threadsResponse(String, Result<[LeoChatThread], any Error>)
    }

    @Dependency(\.chatClient) var chatClient
    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding, .rowTapped:
                return .none

            case .chatEvent(let daemonID, let event, let isOpen):
                apply(event, daemonID: daemonID, isOpen: isOpen, state: &state)
                return .none

            case .newChatButtonTapped:
                state.isShowingNewChat = true
                return .none

            case .newChatPicked:
                state.isShowingNewChat = false
                return .none

            case .refresh(let daemons):
                return .merge(daemons.map { daemon in
                    .run { [chatClient, secrets] send in
                        await send(.threadsResponse(daemon.id, Result { try await chatClient.threads(try secrets.connection(for: daemon)) }))
                    }
                })

            case .threadRead(let ref):
                state.unreadCounts = state.unreadCounts.clearing(ref.leoAgentID)
                return .none

            case .threadsResponse(let daemonID, .success(let threads)):
                state.errors[daemonID] = nil
                state.threads[daemonID] = IdentifiedArray(threads, uniquingIDsWith: { $1 })
                state.unreadCounts = state.unreadCounts.seeding(threads, host: .remote(daemonID))
                return .none

            case .threadsResponse(let daemonID, .failure(let error)):
                state.errors[daemonID] = error.localizedDescription
                return .none
            }
        }
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

    /// Pinned threads (each daemon's assistant first), then the rest by
    /// latest message, then running agents with no thread yet.
    public static func rows(threads: [String: IdentifiedArrayOf<LeoChatThread>], unread: LeoChatUnreadCounts = LeoChatUnreadCounts(), sessions: IdentifiedArrayOf<DaemonSession>) -> [ChatRow] {
        let isMultiDaemon = sessions.count > 1
        let rows = sessions.flatMap { session -> [ChatRow] in
            let daemonThreads = threads[session.id] ?? []
            let daemonName = isMultiDaemon ? session.daemon.name : nil
            let threadRows = daemonThreads.map { thread in
                ChatRow(
                    ref: AgentRef(daemonID: session.id, name: thread.agent), daemonName: daemonName, lastMessage: thread.lastMessage,
                    unread: unread[LeoAgentID(host: .remote(session.id), name: thread.agent)], isRunning: session.agents[id: thread.agent].map { !$0.isStopped } ?? false,
                    section: thread.isPinned ? .pinned : .recent
                )
            }
            let runningRows = session.agents
                .filter { !$0.isStopped && daemonThreads[id: $0.name] == nil }
                .map { ChatRow(ref: AgentRef(daemonID: session.id, name: $0.name), daemonName: daemonName, lastMessage: nil, unread: 0, isRunning: true, section: .running) }
            return threadRows + runningRows
        }
        return rows.sorted(by: isOrderedBefore)
    }

    private static func isOrderedBefore(_ lhs: ChatRow, _ rhs: ChatRow) -> Bool {
        if lhs.section != rhs.section { return lhs.section < rhs.section }
        switch lhs.section {
        case .pinned:
            let (left, right) = (lhs.ref.name == assistant, rhs.ref.name == assistant)
            if left != right { return left }
        case .recent:
            let (left, right) = (lhs.lastMessage?.ts ?? .distantPast, rhs.lastMessage?.ts ?? .distantPast)
            if left != right { return left > right }
        case .running:
            break
        }
        return (lhs.ref.name, lhs.daemonName ?? "") < (rhs.ref.name, rhs.daemonName ?? "")
    }
}
