import ComposableArchitecture
import Foundation
import LeoKit

/// One agent's Leo Chat thread: paged history (oldest first on screen),
/// live `chat.*` events, a task-card filter, answering `ask` and
/// `permission` prompts, attachments, and the composer.
@Reducer
public struct ChatThread {
    public static let pageSize = 50

    public enum AttachmentFile: Equatable, Sendable {
        case failed(String)
        case loaded(URL)
        case loading
    }

    @ObservableState
    public struct State: Equatable, Identifiable {
        public var daemon: PairedDaemon
        public let agentName: String
        /// The live agent, kept in step with the fleet; nil when the daemon
        /// doesn't report it (stopped and pruned, or not connected yet).
        public var agent: Agent?
        @Presents public var alert: AlertState<Never>?
        /// Message ids with an answer in flight.
        public var answering: Set<String> = []
        public var attachmentFiles: [String: AttachmentFile] = [:]
        public var composer = Composer.State()
        /// Messages whose long text or task card is expanded.
        public var expanded: Set<String> = []
        public var hasMore = false
        public var isLoading = false
        public var isLoadingOlder = false
        /// Whether the thread is on screen (drives read marks and banner
        /// suppression).
        public var isOnScreen = false
        /// Every task name seen in this thread, for the filter menu.
        public var knownTasks: Set<String> = []
        public var loadError: String?
        public var messages: IdentifiedArrayOf<LeoChatMessage> = []
        /// The message (usually a task card) the next send replies to.
        public var replyTo: String?
        public var taskFilter: String?

        public var id: AgentRef { ref }
        public var ref: AgentRef { AgentRef(daemonID: daemon.id, name: agentName) }

        public init(daemon: PairedDaemon, agent name: String, live: Agent? = nil) {
            self.daemon = daemon
            agentName = name
            agent = live
        }

        /// Upserts, keeping time order (ties by id: ULIDs sort by time).
        mutating func merge(_ incoming: [LeoChatMessage]) {
            for message in incoming {
                messages[id: message.id] = message
                if let task = message.task { knownTasks.insert(task) }
            }
            messages.sort { ($0.ts, $0.id) < ($1.ts, $1.id) }
        }

        func belongs(_ message: LeoChatMessage) -> Bool {
            message.agent == agentName && (taskFilter == nil || message.task == taskFilter)
        }
    }

    public enum Action {
        case alert(PresentationAction<Never>)
        case answerResponse(messageID: String, value: String, Result<LeoChatMessage?, any Error>)
        case answerTapped(messageID: String, value: String)
        case attachmentNeeded(LeoChatAttachment)
        case attachmentResponse(id: String, Result<URL, any Error>)
        case chatEvent(LeoChatEvent)
        case composer(Composer.Action)
        case expandToggled(String)
        case loadOlderTriggered
        case olderPageResponse(Result<LeoChatPage, any Error>)
        case onScreenChanged(Bool)
        case pageResponse(Result<LeoChatPage, any Error>)
        case replyCancelled
        case replyTapped(String)
        case retryButtonTapped
        case sendResponse(Result<LeoChatMessage, any Error>)
        case task
        case taskFilterChanged(String?)
    }

    enum CancelID { case page }

    @Dependency(\.chatClient) var chatClient
    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.composer, action: \.composer) { Composer() }
        Reduce { state, action in
            switch action {
            case .alert:
                return .none

            case .answerResponse(let id, _, .success(let updated?)):
                state.answering.remove(id)
                state.merge([updated])
                return .none

            case .answerResponse(let id, let value, .success(nil)):
                state.answering.remove(id)
                if let message = state.messages[id: id] { state.messages[id: id] = message.answered(value) }
                return .none

            case .answerResponse(let id, _, .failure(let error)):
                state.answering.remove(id)
                state.alert = Self.failureAlert(title: String(localized: "Couldn't Answer"), message: error.localizedDescription)
                return .none

            case .answerTapped(let id, let value):
                guard state.messages[id: id] != nil, !state.answering.contains(id) else { return .none }
                state.answering.insert(id)
                let (daemon, agent) = (state.daemon, state.agentName)
                return .run { [chatClient, secrets] send in
                    await send(.answerResponse(messageID: id, value: value, Result {
                        try await chatClient.answer(try secrets.connection(for: daemon), agent, id, value)
                    }))
                }

            case .attachmentNeeded(let attachment):
                guard attachment.available else { return .none }
                switch state.attachmentFiles[attachment.id] {
                case .loading, .loaded: return .none
                case .failed, nil: break
                }
                state.attachmentFiles[attachment.id] = .loading
                let daemon = state.daemon
                return .run { [chatClient, secrets] send in
                    await send(.attachmentResponse(id: attachment.id, Result {
                        try await chatClient.download(try secrets.connection(for: daemon), attachment)
                    }))
                }

            case .attachmentResponse(let id, .success(let url)):
                state.attachmentFiles[id] = .loaded(url)
                return .none

            case .attachmentResponse(let id, .failure(let error)):
                state.attachmentFiles[id] = .failed(error.localizedDescription)
                return .none

            case .chatEvent(let event):
                let message = event.message
                guard state.belongs(message) else { return .none }
                if case .updated = event, state.messages[id: message.id] == nil { return .none }
                state.merge([message])
                guard case .message = event, state.isOnScreen, state.taskFilter == nil else { return .none }
                return markRead(message.id, state: state)

            case .composer(.delegate(.send(let outgoing))):
                let (daemon, agent, replyTo) = (state.daemon, state.agentName, state.replyTo)
                return .run { [chatClient, secrets] send in
                    await send(.sendResponse(Result {
                        let connection = try secrets.connection(for: daemon)
                        var ids: [String] = []
                        for file in outgoing.files { ids.append(try await chatClient.upload(connection, file).id) }
                        return try await chatClient.send(connection, agent, LeoChatDraft(text: outgoing.text, replyTo: replyTo, attachmentIDs: ids))
                    }))
                }

            case .composer:
                return .none

            case .expandToggled(let id):
                if state.expanded.remove(id) == nil { state.expanded.insert(id) }
                return .none

            case .loadOlderTriggered:
                guard state.hasMore, !state.isLoading, !state.isLoadingOlder, let oldest = state.messages.first else { return .none }
                state.isLoadingOlder = true
                let query = LeoChatPageQuery(before: oldest.id, limit: Self.pageSize, task: state.taskFilter)
                return fetch(query, state: state) { .olderPageResponse($0) }

            case .olderPageResponse(.success(let page)):
                state.isLoadingOlder = false
                state.hasMore = page.hasMore
                state.merge(page.messages)
                return .none

            case .olderPageResponse(.failure(let error)):
                state.isLoadingOlder = false
                state.loadError = error.localizedDescription
                return .none

            case .onScreenChanged(let isOnScreen):
                state.isOnScreen = isOnScreen
                guard isOnScreen, state.taskFilter == nil, let newest = state.messages.last else { return .none }
                return markRead(newest.id, state: state)

            case .pageResponse(.success(let page)):
                state.isLoading = false
                state.loadError = nil
                state.hasMore = page.hasMore
                state.merge(page.messages)
                guard state.taskFilter == nil, let newest = state.messages.last else { return .none }
                return markRead(newest.id, state: state)

            case .pageResponse(.failure(let error)):
                state.isLoading = false
                state.loadError = error.localizedDescription
                return .none

            case .replyCancelled:
                state.replyTo = nil
                return .none

            case .replyTapped(let id):
                guard state.messages[id: id] != nil else { return .none }
                state.replyTo = id
                return .none

            case .retryButtonTapped, .task:
                return loadNewest(state: &state)

            case .sendResponse(.success(let message)):
                state.composer.reset()
                state.replyTo = nil
                // The live event may have brought it (newer) already.
                if state.messages[id: message.id] == nil, state.belongs(message) { state.merge([message]) }
                return .none

            case .sendResponse(.failure(let error)):
                state.composer.isSending = false
                state.alert = Self.failureAlert(title: String(localized: "Couldn't Send"), message: error.localizedDescription)
                return .none

            case .taskFilterChanged(let task):
                guard task != state.taskFilter else { return .none }
                state.taskFilter = task
                state.messages = []
                state.hasMore = false
                state.expanded = []
                return loadNewest(state: &state)
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    public static func failureAlert(title: String, message: String) -> AlertState<Never> {
        AlertState {
            TextState(title)
        } actions: {
            ButtonState(role: .cancel) { TextState("OK") }
        } message: {
            TextState(message)
        }
    }

    private func loadNewest(state: inout State) -> Effect<Action> {
        state.isLoading = true
        state.isLoadingOlder = false
        return fetch(LeoChatPageQuery(limit: Self.pageSize, task: state.taskFilter), state: state) { .pageResponse($0) }
    }

    private func fetch(_ query: LeoChatPageQuery, state: State, _ action: @escaping @Sendable (Result<LeoChatPage, any Error>) -> Action) -> Effect<Action> {
        let (daemon, agent) = (state.daemon, state.agentName)
        return .run { [chatClient, secrets] send in
            await send(action(Result { try await chatClient.messages(try secrets.connection(for: daemon), agent, query) }))
        }
        .cancellable(id: CancelID.page, cancelInFlight: true)
    }

    /// Read marks are best effort: a failure only leaves the unread count up.
    private func markRead(_ id: String, state: State) -> Effect<Action> {
        let (daemon, agent) = (state.daemon, state.agentName)
        return .run { [chatClient, secrets] _ in
            try? await chatClient.markRead(try secrets.connection(for: daemon), agent, id)
        }
    }
}

extension LeoChatMessage {
    /// This prompt with `value` recorded as its answer.
    func answered(_ value: String) -> LeoChatMessage {
        LeoChatMessage(
            id: id, agent: agent, direction: direction, kind: kind, text: text, transcript: transcript, replyTo: replyTo, task: task,
            runID: runID, state: "answered", answer: value, ts: ts, attachments: attachments, options: options
        )
    }
}
