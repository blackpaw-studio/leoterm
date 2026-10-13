import ComposableArchitecture
import Foundation
import LeoKit

/// One agent's Leo Chat thread: paged history (oldest first on screen),
/// live `chat.*` events, a task-card filter, answering `ask` and
/// `permission` prompts, attachments, and the composer.
@Reducer
public struct ChatThread {
    public static let pageSize = 50
    /// The background task a send (uploads, then the message) runs in.
    public static let sendTaskName = "Leo Chat send"

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
        /// Unsent selections and text of open asks, by message id.
        public var askDrafts: [String: LeoChatAskDraft] = [:]
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
        /// Messages a live event merged since the current page request
        /// started; the page's copy of those is older, so it is skipped.
        public var liveSinceFetch: Set<String> = []
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

        /// Merges a fetched page, skipping messages a live event has
        /// replaced since the request started.
        mutating func mergePage(_ page: LeoChatPage) {
            hasMore = page.hasMore
            merge(page.messages.filter { !liveSinceFetch.contains($0.id) })
            liveSinceFetch = []
        }

        /// Upserts, keeping time order (ties by id: ULIDs sort by time). A
        /// prompt that is no longer open loses its draft.
        mutating func merge(_ incoming: [LeoChatMessage]) {
            for message in incoming {
                messages[id: message.id] = message
                if let task = message.task { knownTasks.insert(task) }
                if !message.isOpen { askDrafts[message.id] = nil }
            }
            messages.sort { ($0.ts, $0.id) < ($1.ts, $1.id) }
        }

        /// An open prompt's input and current draft, when it takes input now.
        func openAsk(_ id: String) -> (input: LeoChatInput, draft: LeoChatAskDraft)? {
            guard let message = messages[id: id], message.isOpen, !answering.contains(id), let input = message.answerInput else { return nil }
            return (input, askDrafts[id] ?? LeoChatAskDraft())
        }

        func belongs(_ message: LeoChatMessage) -> Bool {
            message.agent == agentName && (taskFilter == nil || message.task == taskFilter)
        }
    }

    public enum Action {
        case alert(PresentationAction<Never>)
        case answerResponse(messageID: String, LeoChatAnswer, Result<LeoChatMessage?, any Error>)
        /// A choice tapped: `buttons` answer at once, `radio` and
        /// `checkboxes` update the draft.
        case askChoiceTapped(messageID: String, value: String)
        case askSubmitTapped(messageID: String)
        case askTextChanged(messageID: String, String)
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
        /// Events may have been lost (reconnect or sequence gap): reload the
        /// newest page and merge it by id.
        case resync
        case retryButtonTapped
        case sendResponse(Result<LeoChatMessage, any Error>)
        /// The page just above a prompt that turned out settled (409),
        /// which carries its settled copy.
        case settledMessageResponse(messageID: String, Result<LeoChatPage, any Error>)
        case task
        case taskFilterChanged(String?)
    }

    enum CancelID { case page }

    @Dependency(\.backgroundTask) var backgroundTask
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

            case .answerResponse(let id, let answer, .success(nil)):
                state.answering.remove(id)
                if let message = state.messages[id: id] { state.merge([message.answered(answer)]) }
                return .none

            case .answerResponse(let id, _, .failure(LeoChatAnswerError.settled)):
                // Answered elsewhere or expired: the thread is stale, not wrong.
                state.answering.remove(id)
                state.askDrafts[id] = nil
                return refreshSettled(id, state: state)

            case .answerResponse(let id, _, .failure(let error)):
                state.answering.remove(id)
                state.alert = Self.failureAlert(title: String(localized: "Couldn't Answer"), message: error.localizedDescription)
                return .none

            case .settledMessageResponse(let id, .success(let page)):
                state.merge(page.messages.filter { $0.id == id && state.belongs($0) })
                return .none

            case .settledMessageResponse(_, .failure):
                return .none

            case .askChoiceTapped(let id, let value):
                guard let (input, draft) = state.openAsk(id) else { return .none }
                let chosen = draft.choosing(value, in: input)
                guard input.kind == .buttons else {
                    state.askDrafts[id] = chosen
                    return .none
                }
                guard let answer = chosen.answer(for: input) else { return .none }
                return submit(answer, to: id, state: &state)

            case .askSubmitTapped(let id):
                guard let (input, draft) = state.openAsk(id), let answer = draft.answer(for: input) else { return .none }
                return submit(answer, to: id, state: &state)

            case .askTextChanged(let id, let text):
                guard let (_, draft) = state.openAsk(id) else { return .none }
                state.askDrafts[id] = draft.withText(text)
                return .none

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
                if state.isLoading || state.isLoadingOlder { state.liveSinceFetch.insert(message.id) }
                guard case .message = event, state.isOnScreen, state.taskFilter == nil else { return .none }
                return markRead(message.id, state: state)

            case .composer(.delegate(.send(let outgoing))):
                let (daemon, agent, replyTo) = (state.daemon, state.agentName, state.replyTo)
                return .run { [backgroundTask, chatClient, secrets] send in
                    await send(.sendResponse(Result {
                        try await backgroundTask.run(Self.sendTaskName) {
                            let connection = try secrets.connection(for: daemon)
                            var ids: [String] = []
                            for file in outgoing.files { ids.append(try await chatClient.upload(connection, file).id) }
                            return try await chatClient.send(connection, agent, LeoChatDraft(text: outgoing.text, replyTo: replyTo, attachmentIDs: ids))
                        }
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
                state.liveSinceFetch = []
                let query = LeoChatPageQuery(before: oldest.id, limit: Self.pageSize, task: state.taskFilter)
                return fetch(query, state: state) { .olderPageResponse($0) }

            case .olderPageResponse(.success(let page)):
                state.isLoadingOlder = false
                state.mergePage(page)
                return .none

            case .olderPageResponse(.failure(let error)):
                state.isLoadingOlder = false
                state.liveSinceFetch = []
                state.loadError = error.localizedDescription
                return .none

            case .onScreenChanged(let isOnScreen):
                state.isOnScreen = isOnScreen
                guard isOnScreen, state.taskFilter == nil, let newest = state.messages.last else { return .none }
                return markRead(newest.id, state: state)

            case .pageResponse(.success(let page)):
                state.isLoading = false
                state.loadError = nil
                state.mergePage(page)
                // Off screen (a resync in the background), reading waits
                // for the thread to appear.
                guard state.isOnScreen, state.taskFilter == nil, let newest = state.messages.last else { return .none }
                return markRead(newest.id, state: state)

            case .pageResponse(.failure(let error)):
                state.isLoading = false
                state.liveSinceFetch = []
                state.loadError = error.localizedDescription
                return .none

            case .replyCancelled:
                state.replyTo = nil
                return .none

            case .replyTapped(let id):
                guard state.messages[id: id] != nil else { return .none }
                state.replyTo = id
                return .none

            case .retryButtonTapped, .resync, .task:
                return loadNewest(state: &state)

            case .sendResponse(.success(let message)):
                state.composer.finishSend()
                state.replyTo = nil
                // The live event may have brought it (newer) already.
                if state.messages[id: message.id] == nil, state.belongs(message) { state.merge([message]) }
                return .none

            case .sendResponse(.failure(let error)):
                state.composer.sending = nil
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

    private func submit(_ answer: LeoChatAnswer, to id: String, state: inout State) -> Effect<Action> {
        state.answering.insert(id)
        let (daemon, agent) = (state.daemon, state.agentName)
        return .run { [chatClient, secrets] send in
            await send(.answerResponse(messageID: id, answer, Result {
                try await chatClient.answer(try secrets.connection(for: daemon), agent, id, answer)
            }))
        }
    }

    /// Resyncs after a 409. The newest page may not reach back to the
    /// prompt, so one older than the newest loaded message first fetches
    /// the page just above it, which carries its settled copy.
    private func refreshSettled(_ id: String, state: State) -> Effect<Action> {
        guard let index = state.messages.index(id: id), index + 1 < state.messages.count else { return .send(.resync) }
        let query = LeoChatPageQuery(before: state.messages[index + 1].id, limit: 1, task: state.taskFilter)
        let (daemon, agent) = (state.daemon, state.agentName)
        return .run { [chatClient, secrets] send in
            await send(.settledMessageResponse(messageID: id, Result {
                try await chatClient.messages(try secrets.connection(for: daemon), agent, query)
            }))
            await send(.resync)
        }
    }

    private func loadNewest(state: inout State) -> Effect<Action> {
        state.isLoading = true
        state.isLoadingOlder = false
        state.liveSinceFetch = []
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
