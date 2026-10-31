import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct AppFeatureChatTests {
    static let zeus = AgentRef(daemonID: PairedDaemon.dionysus.id, name: "zeus")

    static func connected() -> AppFeature.State {
        var state = AppFeature.State()
        state.fleet = Fleet.State(daemons: [.dionysus])
        state.fleet.sessions[0].agents = [Agent(.make("zeus"))]
        state.fleet.sessions[0].connection = .connected
        return state
    }

    @Test func tappingAChatOpensItsThreadAndLeavesTheAgentsTabAlone() async {
        var state = Self.connected()
        state.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
        state.chats.threads[Self.zeus.daemonID] = [LeoChatThread(agent: "zeus", unread: 3)]
        state.chats.unreadCounts = LeoChatUnreadCounts().seeding([LeoChatThread(agent: "zeus", unread: 3)], host: .remote(Self.zeus.daemonID))
        let store = TestStore(initialState: state) { AppFeature() }

        await store.send(\.chats.rowTapped, Self.zeus) {
            $0.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
            $0.chats.unreadCounts = LeoChatUnreadCounts()
        }
        #expect(store.state.detail?.ref == Self.zeus)
        // Selecting an agent leaves the open chat alone too.
        await store.send(.agentTapped(Self.zeus))
        #expect(store.state.chat?.ref == Self.zeus)
    }

    @Test func theDetailsChatButtonSwitchesToTheChatsTabAndKeepsTheDetail() async {
        var state = Self.connected()
        state.selectedTab = .agents
        state.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(.detail(.chatButtonTapped)) {
            $0.selectedTab = .chats
            $0.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        }
        #expect(store.state.detail?.ref == Self.zeus)
    }

    @Test func theThreadsInfoButtonSwitchesToTheAgentsTabAndKeepsTheChat() async {
        var state = Self.connected()
        state.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(.chat(.infoButtonTapped)) {
            $0.selectedTab = .agents
            $0.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
        }
        #expect(store.state.chat?.ref == Self.zeus)
        // With the agent's detail already selected, Info only switches tabs.
        await store.send(.tabSelected(.chats)) { $0.selectedTab = .chats }
        await store.send(.chat(.infoButtonTapped)) { $0.selectedTab = .agents }
    }

    @Test func reopeningTheOpenChatChangesNothing() async {
        var state = Self.connected()
        state.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        state.chats.threads[Self.zeus.daemonID] = [LeoChatThread(agent: "zeus")]
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(\.chats.rowTapped, Self.zeus)
    }

    @Test func poppingTheChatClearsItAndParksDrafts() async throws {
        let draft = LeoChatQuestionsDraft(questions: ChatThreadQuestionsTests.questions).choosing("Swift", question: "q1")
        var state = Self.connected()
        state.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
        var thread = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        thread.messages = [try ChatThreadQuestionsTests.questionsCard()]
        thread.questionsDrafts["01"] = draft
        state.chat = thread
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(.chatPopped) {
            $0.chat = nil
            $0.parkedQuestionsDrafts[Self.zeus] = ["01": draft]
        }
        // Nothing open: nothing to clear. The detail is the Agents tab's own.
        await store.send(.chatPopped)
        #expect(store.state.detail?.ref == Self.zeus)
    }

    @Test func poppingTheDetailClearsTheSelectedAgentAndLeavesTheChat() async {
        var state = Self.connected()
        state.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
        state.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(.detailPopped) { $0.detail = nil }
        await store.send(.detailPopped)
        #expect(store.state.chat?.ref == Self.zeus)
    }

    @Test func theNewChatPickerOpensTheThread() async {
        var state = Self.connected()
        state.chats.isShowingNewChat = true
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(\.chats.newChatPicked, Self.zeus) {
            $0.chats.isShowingNewChat = false
            $0.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        }
    }

    @Test func openingAChatFromElsewhereSwitchesToTheChatsTab() async {
        var state = Self.connected()
        state.selectedTab = .agents
        state.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(.chatOpened(Self.zeus)) {
            $0.selectedTab = .chats
            $0.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        }
    }

    @Test func chatEventsReachTheListAndTheOpenThread() async {
        var state = Self.connected()
        state.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        state.chat?.isOnScreen = true
        let reads = LockIsolated<[String]>([])
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.markRead = { _, _, id in reads.withValue { $0.append(id) } }
        }
        let message = LeoChatMessage.make("01", "hi")

        await store.send(\.fleet.eventReceived, (Self.zeus.daemonID, .chat(seq: 3, .message(message))))
        await store.receive(\.chats.chatEvent) {
            $0.chats.threads[Self.zeus.daemonID] = [LeoChatThread(agent: "zeus", lastMessage: message)]
        }
        await store.receive(\.chat.chatEvent) { $0.chat?.messages = [message] }
        await store.finish()
        #expect(reads.value == ["01"])
    }

    @Test func aMessageForAnotherThreadCountsAsUnread() async {
        var state = Self.connected()
        state.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        let store = TestStore(initialState: state) { AppFeature() }
        let message = LeoChatMessage.make("01", "hi", agent: "hera")
        await store.send(\.fleet.eventReceived, (Self.zeus.daemonID, .chat(seq: 3, .message(message))))
        await store.receive(\.chats.chatEvent) {
            $0.chats.threads[Self.zeus.daemonID] = [LeoChatThread(agent: "hera", lastMessage: message)]
            $0.chats.unreadCounts = LeoChatUnreadCounts().seeding([LeoChatThread(agent: "hera", unread: 1)], host: .remote(Self.zeus.daemonID))
        }
    }

    @Test func theChatsEntryLoadsThreadsAndKeepsThemFreshOnReconnect() async {
        var state = Self.connected()
        state.fleet.sessions[0].connection = .connecting
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.threads = { _ in [] }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        // Before the Chats entry shows, a reconnect loads nothing.
        await store.send(\.fleet.connected, (Self.zeus.daemonID, nil, .none, LeoObservedState(agents: [.make("zeus")])))
        await store.send(.chatsEntryAppeared) { $0.chats.isActive = true }
        await store.receive(\.chats.threadsResponse) { $0.chats.threads[Self.zeus.daemonID] = [] }
        await store.send(\.fleet.connected, (Self.zeus.daemonID, nil, .none, LeoObservedState(agents: [.make("zeus")])))
        await store.receive(\.chats.threadsResponse) { $0.chats.threads[Self.zeus.daemonID] = [] }
    }

    @Test func aReconnectOrSequenceGapReloadsTheOpenThread() async {
        var state = Self.connected()
        state.chat = ChatThread.State(daemon: .dionysus, agent: "zeus")
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.messages = { _, _, _ in LeoChatPage(messages: [], hasMore: false) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(\.fleet.connected, (Self.zeus.daemonID, nil, .none, LeoObservedState(agents: [.make("zeus")])))
        await store.receive(\.chat.resync)
        await store.receive(\.chat.pageResponse.success)
        await store.send(\.fleet.sequenceGap, Self.zeus.daemonID)
        await store.receive(\.chat.resync)
        await store.receive(\.chat.pageResponse.success)
        // Another daemon's gap leaves this thread alone.
        await store.send(\.fleet.sequenceGap, "other")
        await store.finish()
    }

    @Test func aChatPushTapSwitchesToTheChatsTabAndOpensTheThread() async {
        var state = Self.connected()
        state.selectedTab = .settings
        state.hasLoadedDaemons = true
        state.chats.filter = .all
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(.chatNotificationOpened(Self.zeus)) {
            $0.selectedTab = .chats
            $0.pendingChat = nil
            $0.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        }
    }

    @Test func aTappedChatNotificationOpensTheThreadOnceTheDaemonIsKnown() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.pushClient = .granted
            $0.pushCleanup = .inMemory(LockIsolated([:]))
        }
        await store.send(.chatNotificationOpened(Self.zeus)) { $0.pendingChat = Self.zeus }
        await store.send(\.fleet.daemonsLoaded, [.dionysus]) {
            $0.hasLoadedDaemons = true
            $0.fleet.sessions = [DaemonSession(daemon: .dionysus)]
            $0.push.daemons = [.dionysus]
            $0.push.hasLoadedDaemons = true
            $0.pendingChat = nil
            $0.chat = ChatThread.State(daemon: .dionysus, agent: "zeus")
        }
        await store.receive(\.push.authorizationChanged, .authorized) { $0.push.authorization = .authorized }
    }

    @Test func aChatNotificationForAForgottenDaemonIsDropped() async {
        var state = AppFeature.State()
        state.hasLoadedDaemons = true
        let store = TestStore(initialState: state) { AppFeature() }
        // Nothing is paired, so the inbox's first chip is decided too.
        await store.send(.chatNotificationOpened(Self.zeus)) { $0.chats.filter = .all }
    }

    @Test func aNotificationReplySendsToTheThread() async {
        let drafts = LockIsolated<[String]>([])
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.pairedDaemons.load = { [.dionysus] }
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.send = { connection, agent, draft in
                drafts.withValue { $0.append("\(connection.daemonID) \(agent) \(draft.text) \(draft.replyTo ?? "-")") }
                return .make("02", draft.text, direction: .inbound)
            }
        }
        let target = LeoPushTarget(daemonID: PairedDaemon.dionysus.id, agent: "zeus")
        await store.send(.chatNotificationAction(.reply(target, text: "on it", replyTo: "01")))
        await store.receive(\.chatNotificationActionFinished)
        #expect(drafts.value == ["d-dionysus zeus on it 01"])
    }

    @Test func aNotificationAnswerAnswersThePrompt() async {
        let answers = LockIsolated<[String]>([])
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.pairedDaemons.load = { [.dionysus] }
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.answer = { _, agent, id, answer in
                answers.withValue { $0.append("\(agent) \(id) \(answer.values.joined())") }
                return nil
            }
        }
        let target = LeoPushTarget(daemonID: PairedDaemon.dionysus.id, agent: "zeus")
        await store.send(.chatNotificationAction(.answer(target, messageID: "01", value: "allow")))
        await store.receive(\.chatNotificationActionFinished)
        #expect(answers.value == ["zeus 01 allow"])
    }

    @Test func aFailedNotificationActionTellsTheUser() async {
        struct Down: Error, LocalizedError { var errorDescription: String? { "offline" } }
        let told = LockIsolated<[String]>([])
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.pairedDaemons.load = { [.dionysus] }
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.answer = { _, _, _, _ in throw Down() }
            $0.chatNotifier.actionFailed = { agent, reason in told.withValue { $0.append("\(agent): \(reason)") } }
        }
        let target = LeoPushTarget(daemonID: PairedDaemon.dionysus.id, agent: "zeus")
        await store.send(.chatNotificationAction(.answer(target, messageID: "01", value: "allow")))
        await store.receive(\.chatNotificationActionFinished)
        #expect(told.value == ["zeus: offline"])
    }

    /// Answered elsewhere or expired: the notification is stale, not a failure.
    @Test func aNotificationAnswerToASettledPromptSaysNothing() async {
        let told = LockIsolated<[String]>([])
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.pairedDaemons.load = { [.dionysus] }
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.answer = { _, _, _, _ in throw LeoChatAnswerError.settled }
            $0.chatNotifier.actionFailed = { agent, reason in told.withValue { $0.append("\(agent): \(reason)") } }
        }
        let target = LeoPushTarget(daemonID: PairedDaemon.dionysus.id, agent: "zeus")
        await store.send(.chatNotificationAction(.answer(target, messageID: "01", value: "allow")))
        await store.receive(\.chatNotificationActionFinished)
        #expect(told.value.isEmpty)
    }

    @Test func aNotificationActionForAnUnpairedDaemonTellsTheUser() async {
        let told = LockIsolated<[String]>([])
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.pairedDaemons.load = { [] }
            $0.chatNotifier.actionFailed = { agent, reason in told.withValue { $0.append("\(agent): \(reason)") } }
        }
        await store.send(.chatNotificationAction(.reply(LeoPushTarget(daemonID: "gone", agent: "zeus"), text: "x", replyTo: nil)))
        await store.receive(\.chatNotificationActionFinished)
        #expect(told.value.count == 1)
    }

    @Test func theOpenThreadFollowsTheLiveAgent() async {
        var state = Self.connected()
        state.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: Agent(.make("zeus")))
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(\.fleet.eventReceived, (Self.zeus.daemonID, .agentStopped(seq: 2, at: nil, agent: "zeus", wakeOnMessage: false))) {
            $0.fleet.sessions[0].agents[id: "zeus"]?.status = .stopped
            $0.fleet.sessions[0].agents[id: "zeus"]?.activity = .unknown
            $0.chat?.agent?.status = .stopped
            $0.chat?.agent?.activity = .unknown
        }
    }

    @Test func showsTheBannerUnlessThatThreadIsOnScreen() {
        var state = Self.connected()
        #expect(!state.isChatOnScreen(Self.zeus))
        state.chat = ChatThread.State(daemon: .dionysus, agent: "zeus")
        #expect(!state.isChatOnScreen(Self.zeus))
        state.chat?.isOnScreen = true
        #expect(state.isChatOnScreen(Self.zeus))
        #expect(!state.isChatOnScreen(AgentRef(daemonID: Self.zeus.daemonID, name: "hera")))
    }
}
