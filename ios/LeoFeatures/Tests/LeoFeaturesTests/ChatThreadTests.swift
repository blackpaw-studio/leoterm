import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

extension LeoChatMessage {
    static func make(
        _ id: String, _ text: String = "", agent: String = "zeus", direction: Direction = .outbound, kind: Kind = .text, task: String? = nil,
        second: Int = 0, state: String? = nil, answer: LeoChatAnswer? = nil, input: LeoChatInput? = nil, attachments: [LeoChatAttachment] = []
    ) -> LeoChatMessage {
        LeoChatMessage(
            id: id, agent: agent, direction: direction, kind: kind, text: text, task: task, runID: task.map { _ in "r-1" },
            state: state, answer: answer, ts: Date(timeIntervalSince1970: TimeInterval(1_000 + second)), attachments: attachments, input: input
        )
    }
}

@MainActor
struct ChatThreadTests {
    static let ref = AgentRef(daemonID: PairedDaemon.dionysus.id, name: "zeus")

    static func state() -> ChatThread.State {
        ChatThread.State(daemon: .dionysus, agent: "zeus")
    }

    static func withSecrets(_ values: inout DependencyValues) {
        values.secrets.load = { _ in DaemonSecrets(token: "t") }
    }

    /// Records `begin <name>` / `end <token>` into `log`.
    static func withBackgroundTask(_ values: inout DependencyValues, log: LockIsolated<[String]>) {
        values.backgroundTask.begin = { name in
            log.withValue { $0.append("begin \(name)") }
            return 7
        }
        values.backgroundTask.end = { token in log.withValue { $0.append("end \(token)") } }
    }

    @Test func openingLoadsTheNewestPageOldestFirstAndMarksItRead() async {
        let queries = LockIsolated<[LeoChatPageQuery]>([])
        let reads = LockIsolated<[String]>([])
        let page = LeoChatPage(messages: [.make("03", second: 3), .make("02", second: 2)], hasMore: true)
        var state = Self.state()
        state.isOnScreen = true
        let store = TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.messages = { _, agent, query in
                #expect(agent == "zeus")
                queries.withValue { $0.append(query) }
                return page
            }
            $0.chatClient.markRead = { _, _, id in reads.withValue { $0.append(id) } }
        }

        await store.send(.task) { $0.isLoading = true }
        await store.receive(\.pageResponse.success) {
            $0.isLoading = false
            $0.messages = [.make("02", second: 2), .make("03", second: 3)]
            $0.hasMore = true
        }
        await store.finish()
        #expect(queries.value == [LeoChatPageQuery(limit: ChatThread.pageSize)])
        #expect(reads.value == ["03"])
    }

    @Test func aResyncReloadsTheNewestPageAndMergesByID() async {
        var state = Self.state()
        state.messages = [.make("01", "draft", second: 1), .make("02", second: 2)]
        let page = LeoChatPage(messages: [.make("03", second: 3), .make("01", "final", second: 1)], hasMore: true)
        let store = TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.messages = { _, _, _ in page }
        }
        await store.send(.resync) { $0.isLoading = true }
        // Off screen, so nothing is marked read.
        await store.receive(\.pageResponse.success) {
            $0.isLoading = false
            $0.hasMore = true
            $0.messages = [.make("01", "final", second: 1), .make("02", second: 2), .make("03", second: 3)]
        }
    }

    @Test func aLiveUpdateDuringAReloadBeatsThePagesOlderCopy() async {
        var state = Self.state()
        state.messages = [.make("01", kind: .ask, state: "open")]
        let gate = AsyncStream<Void>.makeStream()
        let store = TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.messages = { _, _, _ in
                for await _ in gate.stream { break }
                return LeoChatPage(messages: [.make("01", kind: .ask, state: "open")], hasMore: false)
            }
        }
        await store.send(.resync) { $0.isLoading = true }
        await store.send(.chatEvent(.updated(.make("01", kind: .ask, state: "answered", answer: .choice("yes"))))) {
            $0.messages[id: "01"] = .make("01", kind: .ask, state: "answered", answer: .choice("yes"))
            $0.liveSinceFetch = ["01"]
        }
        gate.continuation.yield()
        await store.receive(\.pageResponse.success) {
            $0.isLoading = false
            $0.liveSinceFetch = []
        }
    }

    @Test func scrollingToTheTopLoadsTheOlderPage() async {
        var state = Self.state()
        state.messages = [.make("05", second: 5), .make("06", second: 6)]
        state.hasMore = true
        let queries = LockIsolated<[LeoChatPageQuery]>([])
        let store = TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.messages = { _, _, query in
                queries.withValue { $0.append(query) }
                return LeoChatPage(messages: [.make("04", second: 4)], hasMore: false)
            }
        }

        await store.send(.loadOlderTriggered) { $0.isLoadingOlder = true }
        await store.receive(\.olderPageResponse.success) {
            $0.isLoadingOlder = false
            $0.messages = [.make("04", second: 4), .make("05", second: 5), .make("06", second: 6)]
            $0.hasMore = false
        }
        #expect(queries.value == [LeoChatPageQuery(before: "05", limit: ChatThread.pageSize)])
        // Nothing older: no more requests.
        await store.send(.loadOlderTriggered)
    }

    @Test func aFailedLoadShowsTheReason() async {
        struct Down: Error, LocalizedError { var errorDescription: String? { "daemon down" } }
        let store = TestStore(initialState: Self.state()) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.messages = { _, _, _ in throw Down() }
        }
        await store.send(.task) { $0.isLoading = true }
        await store.receive(\.pageResponse.failure) {
            $0.isLoading = false
            $0.loadError = "daemon down"
        }
    }

    @Test func filteringByTaskReloadsJustThatTasksCards() async {
        var state = Self.state()
        state.messages = [.make("01", task: "wharf", second: 1), .make("02", "hi", second: 2)]
        state.knownTasks = ["wharf"]
        let queries = LockIsolated<[LeoChatPageQuery]>([])
        let store = TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.messages = { _, _, query in
                queries.withValue { $0.append(query) }
                return LeoChatPage(messages: [.make("01", task: "wharf", second: 1)], hasMore: false)
            }
            $0.chatClient.markRead = { _, _, _ in }
        }

        await store.send(.taskFilterChanged("wharf")) {
            $0.taskFilter = "wharf"
            $0.messages = []
            $0.isLoading = true
        }
        await store.receive(\.pageResponse.success) {
            $0.isLoading = false
            $0.messages = [.make("01", task: "wharf", second: 1)]
        }
        #expect(queries.value == [LeoChatPageQuery(limit: ChatThread.pageSize, task: "wharf")])
    }

    @Test func taskNamesAreRememberedForTheFilterMenu() async {
        let store = TestStore(initialState: Self.state()) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.messages = { _, _, _ in
                LeoChatPage(messages: [.make("02", task: "wharf", second: 2), .make("01", task: "digest", second: 1)], hasMore: false)
            }
            $0.chatClient.markRead = { _, _, _ in }
        }
        await store.send(.task) { $0.isLoading = true }
        await store.receive(\.pageResponse.success) {
            $0.isLoading = false
            $0.messages = [.make("01", task: "digest", second: 1), .make("02", task: "wharf", second: 2)]
            $0.knownTasks = ["digest", "wharf"]
        }
    }

    @Test func liveMessagesAppendAndUpdatesReplaceInPlace() async {
        var state = Self.state()
        state.messages = [.make("01", second: 1)]
        state.isOnScreen = true
        let reads = LockIsolated<[String]>([])
        let store = TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.markRead = { _, _, id in reads.withValue { $0.append(id) } }
        }

        await store.send(.chatEvent(.message(.make("02", "reply", second: 2)))) {
            $0.messages = [.make("01", second: 1), .make("02", "reply", second: 2)]
        }
        await store.send(.chatEvent(.updated(.make("01", "edited", second: 1)))) {
            $0.messages[id: "01"] = .make("01", "edited", second: 1)
        }
        // Another agent's message is not this thread's.
        await store.send(.chatEvent(.message(.make("03", agent: "hera"))))
        await store.finish()
        #expect(reads.value == ["02"])
    }

    @Test func aFilteredThreadOnlyTakesThatTasksLiveCards() async {
        var state = Self.state()
        state.taskFilter = "wharf"
        let store = TestStore(initialState: state) { ChatThread() }
        await store.send(.chatEvent(.message(.make("02", "hi", second: 2))))
        await store.send(.chatEvent(.message(.make("03", task: "wharf", second: 3)))) {
            $0.messages = [.make("03", task: "wharf", second: 3)]
            $0.knownTasks = ["wharf"]
        }
    }

    @Test func answeringAnAskRecordsTheDaemonsAnswer() async throws {
        let ask = LeoChatMessage.make("01", "Deploy?", kind: .ask, state: "open", input: try LeoChatInput(kind: .buttons, options: [LeoChatOption(value: "yes", label: "Yes")]))
        var state = Self.state()
        state.messages = [ask]
        let answered = LeoChatMessage.make("01", "Deploy?", kind: .ask, state: "answered", answer: .choice("yes"), input: ask.input)
        let store = TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.answer = { _, agent, id, value in
                #expect([agent, id, value] == ["zeus", "01", "yes"])
                return answered
            }
        }

        await store.send(.answerTapped(messageID: "01", value: "yes")) { $0.answering = ["01"] }
        await store.receive(\.answerResponse) {
            $0.answering = []
            $0.messages[id: "01"] = answered
        }
    }

    @Test func anAnswerWithNoBodyMarksTheMessageAnsweredLocally() async {
        var state = Self.state()
        state.messages = [.make("01", kind: .permission, state: "open")]
        let store = TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.answer = { _, _, _, _ in nil }
        }
        await store.send(.answerTapped(messageID: "01", value: "deny")) { $0.answering = ["01"] }
        await store.receive(\.answerResponse) {
            $0.answering = []
            $0.messages[id: "01"] = .make("01", kind: .permission, state: "answered", answer: .choice("deny"))
        }
    }

    @Test func aFailedAnswerAlertsAndLeavesTheButtons() async {
        struct Gone: Error, LocalizedError { var errorDescription: String? { "expired" } }
        var state = Self.state()
        state.messages = [.make("01", kind: .permission, state: "open")]
        let store = TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.answer = { _, _, _, _ in throw Gone() }
        }
        await store.send(.answerTapped(messageID: "01", value: "allow")) { $0.answering = ["01"] }
        await store.receive(\.answerResponse) {
            $0.answering = []
            $0.alert = ChatThread.failureAlert(title: String(localized: "Couldn't Answer"), message: "expired")
        }
        // A closed prompt can't be answered again.
        await store.send(.answerTapped(messageID: "missing", value: "allow"))
    }

    @Test func sendingUploadsTheFilesThenPostsTheMessageAsAReply() async {
        let photo = ChatFile(id: UUID(0), url: URL(filePath: "/tmp/a.jpg"), filename: "a.jpg", mime: "image/jpeg", kind: .photo)
        var state = Self.state()
        state.messages = [.make("01", task: "wharf", second: 1)]
        state.replyTo = "01"
        state.composer.text = "nice"
        state.composer.attachments = [photo]
        let drafts = LockIsolated<[LeoChatDraft]>([])
        let log = LockIsolated<[String]>([])
        let sent = LeoChatMessage.make("02", "nice", direction: .inbound, second: 2, state: "pending")
        let store = TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            Self.withBackgroundTask(&$0, log: log)
            $0.chatClient.upload = { _, file in
                log.withValue { $0.append("upload \(file.filename)") }
                return LeoChatAttachment(id: "att-\(file.filename)", filename: file.filename, mime: file.mime, bytes: 1)
            }
            $0.chatClient.send = { _, _, draft in
                log.withValue { $0.append("send") }
                drafts.withValue { $0.append(draft) }
                return sent
            }
        }

        await store.send(.composer(.sendButtonTapped)) { $0.composer.sending = Composer.Outgoing(text: "nice", files: [photo]) }
        await store.receive(\.composer.delegate.send)
        await store.receive(\.sendResponse.success) {
            $0.composer.sending = nil
            $0.composer.text = ""
            $0.composer.attachments = []
            $0.replyTo = nil
            $0.messages = [.make("01", task: "wharf", second: 1), sent]
        }
        #expect(drafts.value == [LeoChatDraft(text: "nice", replyTo: "01", attachmentIDs: ["att-a.jpg"])])
        // The uploads and the send finish even if the app leaves the foreground.
        #expect(log.value == ["begin \(ChatThread.sendTaskName)", "upload a.jpg", "send", "end 7"])
    }

    @Test func aFailedSendKeepsTheDraftAndSaysWhy() async {
        struct Refused: Error, LocalizedError { var errorDescription: String? { "too large" } }
        var state = Self.state()
        state.composer.text = "hello"
        let log = LockIsolated<[String]>([])
        let store = TestStore(initialState: state) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            Self.withBackgroundTask(&$0, log: log)
            $0.chatClient.send = { _, _, _ in throw Refused() }
        }
        await store.send(.composer(.sendButtonTapped)) { $0.composer.sending = Composer.Outgoing(text: "hello", files: []) }
        await store.receive(\.composer.delegate.send)
        await store.receive(\.sendResponse.failure) {
            $0.composer.sending = nil
            $0.alert = ChatThread.failureAlert(title: String(localized: "Couldn't Send"), message: "too large")
        }
        #expect(log.value == ["begin \(ChatThread.sendTaskName)", "end 7"])
    }

    @Test func aSentMessageThatAlreadyArrivedLiveIsNotDuplicated() async {
        var state = Self.state()
        let sent = LeoChatMessage.make("02", "hi", direction: .inbound, second: 2, state: "delivered")
        state.messages = [sent]
        state.composer.sending = Composer.Outgoing(text: "hi", files: [])
        let store = TestStore(initialState: state) { ChatThread() }
        await store.send(.sendResponse(.success(.make("02", "hi", direction: .inbound, second: 2, state: "pending")))) {
            $0.composer.sending = nil
        }
    }

    @Test func aSendClearsOnlyWhatItSent() async {
        let voice = ChatFile(id: UUID(1), url: URL(filePath: "/tmp/v.m4a"), filename: "Voice note.m4a", mime: "audio/mp4", kind: .voice)
        let photo = ChatFile(id: UUID(2), url: URL(filePath: "/tmp/a.jpg"), filename: "a.jpg", mime: "image/jpeg", kind: .photo)
        var state = Self.state()
        state.composer.sending = Composer.Outgoing(text: "first", files: [voice])
        // Typed and attached while the send was in flight.
        state.composer.text = "second thought"
        state.composer.attachments = [voice, photo]
        let store = TestStore(initialState: state) { ChatThread() }
        await store.send(.sendResponse(.success(.make("02", "first", direction: .inbound, second: 2)))) {
            $0.composer.sending = nil
            $0.composer.attachments = [photo]
            $0.messages = [.make("02", "first", direction: .inbound, second: 2)]
        }
    }

    @Test func aSendClearsTheTextItSentEvenWithTrailingSpace() async {
        var state = Self.state()
        state.composer.sending = Composer.Outgoing(text: "first", files: [])
        state.composer.text = "first \n"
        let store = TestStore(initialState: state) { ChatThread() }
        await store.send(.sendResponse(.success(.make("02", "first", direction: .inbound, second: 2)))) {
            $0.composer.sending = nil
            $0.composer.text = ""
            $0.messages = [.make("02", "first", direction: .inbound, second: 2)]
        }
    }

    @Test func aFailedVoiceSendLeavesTheNoteToRetry() async {
        struct Offline: Error, LocalizedError { var errorDescription: String? { "offline" } }
        let voice = ChatFile(id: UUID(1), url: URL(filePath: "/tmp/v.m4a"), filename: "Voice note.m4a", mime: "audio/mp4", kind: .voice)
        var state = Self.state()
        state.composer.sending = Composer.Outgoing(text: "", files: [voice])
        state.composer.attachments = [voice]
        let store = TestStore(initialState: state) { ChatThread() }
        await store.send(.sendResponse(.failure(Offline()))) {
            $0.composer.sending = nil
            $0.alert = ChatThread.failureAlert(title: String(localized: "Couldn't Send"), message: "offline")
        }
        #expect(store.state.composer.outgoing == Composer.Outgoing(text: "", files: [voice]))
        #expect(store.state.composer.canSend)
    }

    @Test func showMoreAndTaskCardsToggleExpansion() async {
        let store = TestStore(initialState: Self.state()) { ChatThread() }
        await store.send(.expandToggled("01")) { $0.expanded = ["01"] }
        await store.send(.expandToggled("01")) { $0.expanded = [] }
    }

    @Test func replyingToACardAndCancelling() async {
        var state = Self.state()
        state.messages = [.make("01", task: "wharf")]
        let store = TestStore(initialState: state) { ChatThread() }
        await store.send(.replyTapped("01")) { $0.replyTo = "01" }
        await store.send(.replyCancelled) { $0.replyTo = nil }
    }

    @Test func attachmentsDownloadOnceIntoLocalFiles() async {
        let attachment = LeoChatAttachment(id: "att1", filename: "a.png", mime: "image/png", bytes: 3)
        let downloads = LockIsolated(0)
        let store = TestStore(initialState: Self.state()) {
            ChatThread()
        } withDependencies: {
            Self.withSecrets(&$0)
            $0.chatClient.download = { _, attachment in
                downloads.withValue { $0 += 1 }
                return URL(filePath: "/cache/\(attachment.id)/\(attachment.filename)")
            }
        }
        await store.send(.attachmentNeeded(attachment)) { $0.attachmentFiles["att1"] = .loading }
        await store.receive(\.attachmentResponse) { $0.attachmentFiles["att1"] = .loaded(URL(filePath: "/cache/att1/a.png")) }
        await store.send(.attachmentNeeded(attachment))
        #expect(downloads.value == 1)
    }

    @Test func aPrunedAttachmentIsNotRequested() async {
        let store = TestStore(initialState: Self.state()) { ChatThread() }
        await store.send(.attachmentNeeded(LeoChatAttachment(id: "old", filename: "a", mime: "image/png", bytes: 1, available: false)))
    }

    @Test func missingCredentialsFailTheLoad() async {
        let store = TestStore(initialState: Self.state()) {
            ChatThread()
        } withDependencies: {
            $0.secrets.load = { _ in nil }
        }
        await store.send(.task) { $0.isLoading = true }
        await store.receive(\.pageResponse.failure) {
            $0.isLoading = false
            $0.loadError = ChatConnectionError.missingCredentials.localizedDescription
        }
    }
}
