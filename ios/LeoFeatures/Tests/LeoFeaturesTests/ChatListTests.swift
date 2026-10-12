import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct ChatListTests {
    static let daemon = PairedDaemon.dionysus.id

    static func session(_ daemon: PairedDaemon = .dionysus, agents: [Agent]) -> DaemonSession {
        var session = DaemonSession(daemon: daemon)
        session.agents = IdentifiedArray(uniqueElements: agents)
        return session
    }

    @Test func rowsArePinnedAssistantFirstThenRecentThenRunning() {
        let threads: IdentifiedArrayOf<LeoChatThread> = [
            LeoChatThread(agent: "zeus", lastMessage: .make("01", agent: "zeus", second: 1)),
            LeoChatThread(agent: "hera", lastMessage: .make("05", agent: "hera", second: 5), unread: 2),
            LeoChatThread(agent: "rocket", lastMessage: .make("02", agent: "rocket", second: 2), isPinned: true),
            LeoChatThread(agent: "assistant", lastMessage: .make("00", agent: "assistant", second: 0), isPinned: true),
        ]
        let sessions: IdentifiedArrayOf<DaemonSession> = [Self.session(agents: [
            Agent(name: "zeus", status: .running), Agent(name: "apollo", status: .running), Agent(name: "ares", status: .stopped),
            Agent(name: "athena", status: .running),
        ])]

        let rows = ChatList.rows(threads: [Self.daemon: threads], sessions: sessions)

        #expect(rows.map(\.ref.name) == ["assistant", "rocket", "hera", "zeus", "apollo", "athena"])
        #expect(rows.map(\.section) == [.pinned, .pinned, .recent, .recent, .running, .running])
        #expect(rows.first { $0.ref.name == "hera" }?.unread == 2)
        #expect(rows.first { $0.ref.name == "zeus" }?.isRunning == true)
        #expect(rows.first { $0.ref.name == "rocket" }?.isRunning == false)
    }

    @Test func rowsNameTheDaemonOnlyWhenThereIsMoreThanOne() {
        let one = ChatList.rows(threads: [:], sessions: [Self.session(agents: [Agent(name: "zeus", status: .running)])])
        #expect(one.map(\.daemonName) == [nil])
        let two = ChatList.rows(threads: [:], sessions: [
            Self.session(agents: [Agent(name: "zeus", status: .running)]), Self.session(.hestia, agents: [Agent(name: "zeus", status: .running)]),
        ])
        #expect(two.map(\.daemonName) == ["dionysus", "hestia"])
    }

    @Test func refreshingLoadsEachDaemonsThreads() async {
        let store = TestStore(initialState: ChatList.State()) {
            ChatList()
        } withDependencies: {
            $0.secrets.load = { id in id == PairedDaemon.hestia.id ? nil : DaemonSecrets(token: "t") }
            $0.chatClient.threads = { _ in [LeoChatThread(agent: "zeus", unread: 1)] }
        }

        // The two daemons answer in either order.
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.refresh([.dionysus, .hestia]))
        await store.skipReceivedActions()
        store.assert {
            $0.threads[Self.daemon] = [LeoChatThread(agent: "zeus", unread: 1)]
            $0.errors[PairedDaemon.hestia.id] = ChatConnectionError.missingCredentials.localizedDescription
        }
    }

    @Test func anOutboundMessageBumpsItsThreadAndUnread() async {
        var state = ChatList.State()
        state.threads[Self.daemon] = [LeoChatThread(agent: "zeus", lastMessage: .make("01"), unread: 0)]
        let store = TestStore(initialState: state) { ChatList() }

        await store.send(.chatEvent(Self.daemon, .message(.make("02", "hi", second: 2)), isOpen: false)) {
            $0.threads[Self.daemon]?[id: "zeus"] = LeoChatThread(agent: "zeus", lastMessage: .make("02", "hi", second: 2), unread: 1)
        }
        // Inbound (what this device sent) and an open thread don't count.
        await store.send(.chatEvent(Self.daemon, .message(.make("03", direction: .inbound, second: 3)), isOpen: false)) {
            $0.threads[Self.daemon]?[id: "zeus"]?.lastMessage = .make("03", direction: .inbound, second: 3)
        }
        await store.send(.chatEvent(Self.daemon, .message(.make("04", second: 4)), isOpen: true)) {
            $0.threads[Self.daemon]?[id: "zeus"]?.lastMessage = .make("04", second: 4)
        }
    }

    @Test func aFirstMessageStartsAThread() async {
        let store = TestStore(initialState: ChatList.State()) { ChatList() }
        await store.send(.chatEvent(Self.daemon, .message(.make("01", agent: "hera")), isOpen: false)) {
            $0.threads[Self.daemon] = [LeoChatThread(agent: "hera", lastMessage: .make("01", agent: "hera"), unread: 1)]
        }
    }

    @Test func anUpdateRefreshesTheLastMessageOnly() async {
        var state = ChatList.State()
        state.threads[Self.daemon] = [LeoChatThread(agent: "zeus", lastMessage: .make("02", second: 2), unread: 1)]
        let store = TestStore(initialState: state) { ChatList() }
        await store.send(.chatEvent(Self.daemon, .updated(.make("01", "old", second: 1)), isOpen: false))
        await store.send(.chatEvent(Self.daemon, .updated(.make("02", "transcribed", second: 2)), isOpen: false)) {
            $0.threads[Self.daemon]?[id: "zeus"]?.lastMessage = .make("02", "transcribed", second: 2)
        }
    }

    @Test func openingAThreadClearsItsUnread() async {
        var state = ChatList.State()
        state.threads[Self.daemon] = [LeoChatThread(agent: "zeus", unread: 4)]
        let store = TestStore(initialState: state) { ChatList() }
        await store.send(.threadRead(AgentRef(daemonID: Self.daemon, name: "zeus"))) {
            $0.threads[Self.daemon]?[id: "zeus"]?.unread = 0
        }
    }

    @Test func theUnreadTotalSumsEveryDaemon() {
        var state = ChatList.State()
        state.threads = [Self.daemon: [LeoChatThread(agent: "a", unread: 2)], "other": [LeoChatThread(agent: "b", unread: 3)]]
        #expect(state.unreadTotal == 5)
    }

    @Test func theNewChatPicker() async {
        let store = TestStore(initialState: ChatList.State()) { ChatList() }
        await store.send(.newChatButtonTapped) { $0.isShowingNewChat = true }
        await store.send(.newChatPicked(AgentRef(daemonID: Self.daemon, name: "zeus"))) { $0.isShowingNewChat = false }
    }
}
