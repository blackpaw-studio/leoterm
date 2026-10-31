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
        /// The full terminal, pushed from the header's Terminal button.
        @Presents public var terminal: Terminal.State?
        /// Message ids with an answer in flight.
        public var answering: Set<String> = []
        /// Unsent selections and text of open asks, by message id.
        public var askDrafts: [String: LeoChatAskDraft] = [:]
        public var attachmentFiles: [String: AttachmentFile] = [:]
        public var composer = Composer.State()
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
        /// Unsent answers of open questions cards, by message id.
        public var questionsDrafts: [String: LeoChatQuestionsDraft] = [:]
        /// The daemon's reason a questions card's last answer was refused,
        /// shown on the card itself, by message id.
        public var questionsErrors: [String: String] = [:]
        /// The message (usually a task card) the next send replies to.
        public var replyTo: String?
        public var taskFilter: String?
        /// The live terminal under the header.
        public var strip: TerminalStrip.State

        public var id: AgentRef { ref }
        public var ref: AgentRef { AgentRef(daemonID: daemon.id, name: agentName) }

        public init(daemon: PairedDaemon, agent name: String, live: Agent? = nil) {
            self.daemon = daemon
            agentName = name
            agent = live
            strip = TerminalStrip.State(daemon: daemon, agentName: name, isAgentRunning: live?.canOpenTerminal ?? false)
        }

        /// Whether the strip should hold a connection: only for a known agent,
        /// on screen, and shown.
        public var wantsStripConnection: Bool { isOnScreen && strip.isShown && agent != nil }

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
                if !message.isOpen { dropDrafts(of: message.id) }
            }
            messages.sort { ($0.ts, $0.id) < ($1.ts, $1.id) }
        }

        /// An open prompt's input and current draft, when it takes input now.
        func openAsk(_ id: String) -> (input: LeoChatInput, draft: LeoChatAskDraft)? {
            guard let message = messages[id: id], message.isOpen, !answering.contains(id), let input = message.answerInput else { return nil }
            return (input, askDrafts[id] ?? LeoChatAskDraft())
        }

        /// An open questions card's questions and current draft, when it takes input now.
        func openQuestions(_ id: String) -> (questions: [LeoChatQuestion], draft: LeoChatQuestionsDraft)? {
            guard let message = messages[id: id], message.isOpen, !answering.contains(id),
                  let input = message.input, input.kind == .questions else { return nil }
            return (input.questions, questionsDrafts[id] ?? LeoChatQuestionsDraft(questions: input.questions))
        }

        mutating func dropDrafts(of id: String) {
            askDrafts[id] = nil
            questionsDrafts[id] = nil
            questionsErrors[id] = nil
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
        /// The header's Info button; the app root opens the agent's detail.
        case infoButtonTapped
        case loadOlderTriggered
        case olderPageResponse(Result<LeoChatPage, any Error>)
        case onScreenChanged(Bool)
        case pageResponse(Result<LeoChatPage, any Error>)
        case strip(TerminalStrip.Action)
        /// An option of a questions card tapped: updates its draft.
        case questionChoiceTapped(messageID: String, questionID: String, value: String)
        case questionTextChanged(messageID: String, questionID: String, String)
        case questionsDismissTapped(messageID: String)
        /// The answer or the dismissal came back; the message is nil when the
        /// daemon settled the card without returning it.
        case questionsResponse(messageID: String, Result<LeoChatMessage?, any Error>)
        case questionsSubmitTapped(messageID: String)
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
        case terminal(PresentationAction<Terminal.Action>)
        case terminalButtonTapped
    }

    enum CancelID { case page }

    @Dependency(\.backgroundTask) var backgroundTask
    @Dependency(\.chatClient) var chatClient
    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.composer, action: \.composer) { Composer() }
        Scope(state: \.strip, action: \.strip) { TerminalStrip() }
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

            case .composer, .infoButtonTapped, .strip, .terminal:
                return .none

            case .terminalButtonTapped:
                state.terminal = Terminal.State(daemon: state.daemon, agentName: state.agentName, isAgentRunning: state.agent?.canOpenTerminal ?? false)
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

            case .questionChoiceTapped(let id, let questionID, let value):
                guard let (_, draft) = state.openQuestions(id) else { return .none }
                state.questionsDrafts[id] = draft.choosing(value, question: questionID)
                return .none

            case .questionTextChanged(let id, let questionID, let text):
                guard let (_, draft) = state.openQuestions(id) else { return .none }
                state.questionsDrafts[id] = draft.withText(text, question: questionID)
                return .none

            case .questionsSubmitTapped(let id):
                guard let (_, draft) = state.openQuestions(id), draft.isComplete else { return .none }
                let answers = draft.answersPayload
                return settleQuestions(id, state: &state) { chatClient, connection, agent in
                    try await chatClient.answerQuestions(connection, agent, id, answers)
                }

            case .questionsDismissTapped(let id):
                guard state.openQuestions(id) != nil else { return .none }
                return settleQuestions(id, state: &state) { chatClient, connection, agent in
                    try await chatClient.dismiss(connection, agent, id)
                }

            case .questionsResponse(let id, .success(let updated?)):
                state.answering.remove(id)
                state.merge([updated])
                return .none

            case .questionsResponse(let id, .success(nil)):
                // Settled, but the daemon sent no copy: the live event or a reload brings it.
                state.answering.remove(id)
                return .send(.resync)

            case .questionsResponse(let id, .failure(LeoChatAnswerError.settled)):
                state.answering.remove(id)
                state.dropDrafts(of: id)
                return refreshSettled(id, state: state)

            case .questionsResponse(let id, .failure(let error)):
                state.answering.remove(id)
                state.questionsErrors[id] = error.localizedDescription
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
                return loadNewest(state: &state)
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$terminal, action: \.terminal) { Terminal() }
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
}
