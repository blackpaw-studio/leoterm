import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct ChatListTests {
    static let daemon = PairedDaemon.dionysus.id

    static let host = LeoHostID.remote(daemon)

    static func counts(zeus: Int = 0, hera: Int = 0) -> LeoChatUnreadCounts {
        LeoChatUnreadCounts().seeding(
            [LeoChatThread(agent: "zeus", unread: zeus), LeoChatThread(agent: "hera", unread: hera)], host: host)
    }

    static func session(_ daemon: PairedDaemon = .dionysus, agents: [Agent]) -> DaemonSession {
        var session = DaemonSession(daemon: daemon)
        session.agents = IdentifiedArray(uniqueElements: agents)
        return session
    }

    @Test func rowsKeepTheirSectionAndSortByRecencyWithAssistantFirst() {
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

        let unread = LeoChatUnreadCounts().seeding(Array(threads), host: Self.host)

        let rows = ChatList.rows(threads: [Self.daemon: threads], unread: unread, sessions: sessions)

        #expect(rows.map(\.ref.name) == ["assistant", "hera", "rocket", "zeus", "apollo", "athena"])
        #expect(rows.first { $0.ref.name == "assistant" }?.section == .pinned)
        #expect(rows.first { $0.ref.name == "hera" }?.section == .recent)
        #expect(rows.first { $0.ref.name == "apollo" }?.section == .running)
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
            $0.chatClient.openAsks = { _ in nil }
            $0.chatClient.seen = { _ in nil }
            $0.inboxSeenStore.load = { LeoInboxSeenState() }
            $0.inboxSeenStore.save = { _ in }
        }

        // The two daemons answer in either order.
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.refresh([.dionysus, .hestia]))
        await store.skipReceivedActions()
        store.assert {
            $0.threads[Self.daemon] = [LeoChatThread(agent: "zeus", unread: 1)]
            $0.unreadCounts = LeoChatUnreadCounts().seeding([LeoChatThread(agent: "zeus", unread: 1)], host: Self.host)
            $0.errors[PairedDaemon.hestia.id] = ChatConnectionError.missingCredentials.localizedDescription
        }
    }

    @Test func anOutboundMessageBumpsItsThreadAndUnread() async {
        var state = ChatList.State()
        state.threads[Self.daemon] = [LeoChatThread(agent: "zeus", lastMessage: .make("01"), unread: 0)]
        let store = TestStore(initialState: state) { ChatList() }
        store.exhaustivity = .off(showSkippedAssertions: false) // the open-asks bookkeeping also sees chat events

        await store.send(.chatEvent(Self.daemon, .message(.make("02", "hi", second: 2)), isOpen: false)) {
            $0.threads[Self.daemon]?[id: "zeus"]?.lastMessage = .make("02", "hi", second: 2)
            $0.unreadCounts = Self.counts(zeus: 1)
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
        store.exhaustivity = .off(showSkippedAssertions: false) // the open-asks bookkeeping also sees chat events
        await store.send(.chatEvent(Self.daemon, .message(.make("01", agent: "hera")), isOpen: false)) {
            $0.threads[Self.daemon] = [LeoChatThread(agent: "hera", lastMessage: .make("01", agent: "hera"))]
            $0.unreadCounts = Self.counts(hera: 1)
        }
    }

    @Test func anUpdateRefreshesTheLastMessageOnly() async {
        var state = ChatList.State()
        state.threads[Self.daemon] = [LeoChatThread(agent: "zeus", lastMessage: .make("02", second: 2))]
        state.unreadCounts = Self.counts(zeus: 1)
        let store = TestStore(initialState: state) { ChatList() }
        store.exhaustivity = .off(showSkippedAssertions: false) // the open-asks bookkeeping also sees chat events
        await store.send(.chatEvent(Self.daemon, .updated(.make("01", "old", second: 1)), isOpen: false))
        await store.send(.chatEvent(Self.daemon, .updated(.make("02", "transcribed", second: 2)), isOpen: false)) {
            $0.threads[Self.daemon]?[id: "zeus"]?.lastMessage = .make("02", "transcribed", second: 2)
        }
    }

    @Test func openingAThreadClearsItsUnread() async {
        var state = ChatList.State()
        state.threads[Self.daemon] = [LeoChatThread(agent: "zeus", unread: 4)]
        state.unreadCounts = Self.counts(zeus: 4)
        let store = TestStore(initialState: state) { ChatList() }
        await store.send(.threadRead(AgentRef(daemonID: Self.daemon, name: "zeus"))) {
            $0.unreadCounts = LeoChatUnreadCounts()
        }
    }

    @Test func theUnreadTotalSumsEveryDaemon() {
        var state = ChatList.State()
        state.threads = [Self.daemon: [LeoChatThread(agent: "a", unread: 2)], "other": [LeoChatThread(agent: "b", unread: 3)]]
        state.unreadCounts = LeoChatUnreadCounts()
            .seeding([LeoChatThread(agent: "a", unread: 2)], host: Self.host)
            .seeding([LeoChatThread(agent: "b", unread: 3)], host: .remote("other"))
        #expect(state.unreadTotal == 5)
    }

    @Test func aFreshLoadReplacesLiveCountsWithTheDaemonsOwn() async {
        var state = ChatList.State()
        state.threads[Self.daemon] = [LeoChatThread(agent: "zeus", lastMessage: .make("01"))]
        state.unreadCounts = Self.counts(zeus: 3)
        let store = TestStore(initialState: state) { ChatList() }
        store.exhaustivity = .off(showSkippedAssertions: false) // the open-asks bookkeeping also sees chat events
        let fresh = [LeoChatThread(agent: "zeus", lastMessage: .make("01"), unread: 1)]
        await store.send(.threadsResponse(Self.daemon, .success(fresh))) {
            $0.threads[Self.daemon] = IdentifiedArray(uniqueElements: fresh)
            $0.unreadCounts = Self.counts(zeus: 1)
        }
    }

    @Test func aMessageFromAnOlderPointDoesNotCountAsUnread() async {
        var state = ChatList.State()
        state.threads[Self.daemon] = [LeoChatThread(agent: "zeus", lastMessage: .make("05", second: 5))]
        let store = TestStore(initialState: state) { ChatList() }
        store.exhaustivity = .off(showSkippedAssertions: false) // the open-asks bookkeeping also sees chat events
        await store.send(.chatEvent(Self.daemon, .message(.make("02", second: 2)), isOpen: false))
    }

    @Test func theNewChatPicker() async {
        let store = TestStore(initialState: ChatList.State()) { ChatList() }
        await store.send(.newChatButtonTapped) { $0.isShowingNewChat = true }
        await store.send(.newChatPicked(AgentRef(daemonID: Self.daemon, name: "zeus"))) { $0.isShowingNewChat = false }
    }

    // MARK: - Inbox buckets, sort, filter

    static func agent(_ name: String, _ state: LeoAttentionState?, status: LeoAgentStatus = .running, activity: LeoActivity? = nil) -> Agent {
        Agent(name: name, status: status, activity: activity, attention: state.map { .state($0, 1) })
    }

    static func rows(_ agents: [Agent], messages: [String: Int] = [:]) -> [ChatRow] {
        let threads = IdentifiedArray(uniqueElements: agents.map { agent in
            LeoChatThread(agent: agent.name, lastMessage: messages[agent.name].map { .make("m\($0)", agent: agent.name, second: $0) })
        })
        return ChatList.rows(threads: [daemon: threads], sessions: [session(agents: agents)])
    }

    @Test func statusBucketsFollowAgentPriority() {
        let rows = Self.rows([
            Self.agent("asks", .needsInput), Self.agent("broke", .errored), Self.agent("done", .finished), Self.agent("busy", .working),
            Self.agent("busy2", nil, activity: .working), Self.agent("quiet", nil), Self.agent("off", nil, status: .stopped),
        ])
        let buckets = Dictionary(uniqueKeysWithValues: rows.map { ($0.ref.name, $0.bucket) })
        #expect(buckets == ["asks": .needsYou, "broke": .done, "done": .done, "busy": .working, "busy2": .working, "quiet": nil, "off": nil])
    }

    @Test func aThreadWhoseAgentIsNotInTheFleetHasNoDotAndSortsAsIdle() {
        let threads: IdentifiedArrayOf<LeoChatThread> = [
            LeoChatThread(agent: "ghost", lastMessage: .make("09", agent: "ghost", second: 9)),
            LeoChatThread(agent: "busy", lastMessage: .make("01", agent: "busy", second: 1)),
        ]
        let rows = ChatList.rows(threads: [Self.daemon: threads], sessions: [Self.session(agents: [Self.agent("busy", .working)])])
        #expect(rows.map(\.ref.name) == ["busy", "ghost"])
        #expect(rows.last?.bucket == nil)
        #expect(rows.last?.agent == nil)
    }

    @Test func needsYouThenWorkingThenEverythingElseNewestFirst() {
        let rows = Self.rows(
            [
                Self.agent("old-ask", .needsInput), Self.agent("new-ask", .errored), Self.agent("work", .working), Self.agent("done", .finished),
                Self.agent("idle", nil),
            ],
            messages: ["old-ask": 1, "new-ask": 2, "work": 9, "done": 5, "idle": 6]
        )
        #expect(rows.map(\.ref.name) == ["old-ask", "work", "idle", "done", "new-ask"])
    }

    @Test func theAssistantTopsItsBucketButNotNeedsYou() {
        let threads: IdentifiedArrayOf<LeoChatThread> = [
            LeoChatThread(agent: "assistant", lastMessage: .make("01", agent: "assistant", second: 1), isPinned: true),
            LeoChatThread(agent: "zeus", lastMessage: .make("09", agent: "zeus", second: 9)),
            LeoChatThread(agent: "hera", lastMessage: .make("05", agent: "hera", second: 5)),
        ]
        let idle = ChatList.rows(threads: [Self.daemon: threads], sessions: [Self.session(agents: [Self.agent("assistant", nil), Self.agent("zeus", nil), Self.agent("hera", .needsInput)])])
        #expect(idle.map(\.ref.name) == ["hera", "assistant", "zeus"])
        let working = ChatList.rows(threads: [Self.daemon: threads], sessions: [Self.session(agents: [Self.agent("assistant", .working), Self.agent("zeus", .working), Self.agent("hera", nil)])])
        #expect(working.map(\.ref.name) == ["assistant", "zeus", "hera"])
    }

    @Test func filtersSelectTheirBucketAndAllKeepsEverything() {
        let rows = Self.rows([Self.agent("asks", .needsInput), Self.agent("busy", .working), Self.agent("done", .finished), Self.agent("quiet", nil)])
        func names(_ filter: ChatFilter?) -> [String] { ChatList.visible(rows, filter: filter, search: "").map(\.ref.name) }
        #expect(names(.needsYou) == ["asks"])
        #expect(names(.working) == ["busy"])
        #expect(names(.done) == ["done"])
        #expect(Set(names(.all)) == ["asks", "busy", "done", "quiet"])
        #expect(Set(names(nil)) == ["asks", "busy", "done", "quiet"])
    }

    @Test func searchMatchesNameAndLastMessageCaseInsensitively() {
        let threads: IdentifiedArrayOf<LeoChatThread> = [
            LeoChatThread(agent: "Zeus", lastMessage: .make("01", "deploy finished", agent: "Zeus", second: 1)),
            LeoChatThread(agent: "hera", lastMessage: .make("02", "ready for review", agent: "hera", second: 2)),
        ]
        let rows = ChatList.rows(threads: [Self.daemon: threads], sessions: [Self.session(agents: [Self.agent("Zeus", nil), Self.agent("hera", nil)])])
        func names(_ search: String, _ filter: ChatFilter? = .all) -> [String] { ChatList.visible(rows, filter: filter, search: search).map(\.ref.name) }
        #expect(names("zeus") == ["Zeus"])
        #expect(names("REVIEW") == ["hera"])
        #expect(names("  ") == ["hera", "Zeus"])
        #expect(names("nothing").isEmpty)
        #expect(names("zeus", .working).isEmpty)
    }

    @Test func countsCoverNeedsYouAndWorking() {
        let rows = Self.rows([Self.agent("a", .needsInput), Self.agent("b", .errored), Self.agent("c", .working), Self.agent("d", .finished)])
        #expect(ChatList.counts(rows) == ChatCounts(needsYou: 1, working: 1))
    }

    @Test func previewPrefixNamesWhatTheAgentWants() {
        let rows = Self.rows([Self.agent("a", .needsInput), Self.agent("b", .errored), Self.agent("c", .working), Self.agent("d", nil)])
        let prefixes = Dictionary(uniqueKeysWithValues: rows.map { ($0.ref.name, $0.previewPrefix) })
        #expect(prefixes == ["a": .asks, "b": .error, "c": nil, "d": nil])
    }

    @Test func pickingAChipSetsTheFilterAndSearchBinds() async {
        let store = TestStore(initialState: ChatList.State()) { ChatList() }
        #expect(store.state.filter == nil)
        await store.send(.filterPicked(.working)) { $0.filter = .working }
        await store.send(.binding(.set(\.searchText, "ze"))) { $0.searchText = "ze" }
    }

    // MARK: Inbox

    nonisolated static let epoch = Date(timeIntervalSince1970: 1_795_539_600)

    static func ask(_ id: String, agent: String = "zeus", state: String = "open") -> LeoChatMessage {
        LeoChatMessage(
            id: id, agent: agent, direction: .outbound, kind: .ask, text: "Ship it?", state: state, ts: epoch,
            input: try? LeoChatInput(kind: .buttons, options: [LeoChatOption(value: "y", label: "Yes")])
        )
    }

    static func listState(asks: [LeoChatMessage] = []) -> ChatList.State {
        var state = ChatList.State()
        state.daemons[daemon] = .dionysus
        state.openAsks.seed(host: host, messages: asks, complete: true)
        return state
    }

    static func connected(_ agents: [Agent]) -> IdentifiedArrayOf<DaemonSession> {
        var session = session(agents: agents)
        session.connection = .connected
        session.bootID = "boot"
        return [session]
    }

    @Test func anOpenAskIsBlockedAndAFinishedAgentIsAnUnreadFinishedItem() {
        let state = Self.listState(asks: [Self.ask("q1")])
        let finished = Agent(name: "hera", status: .running, attention: LeoAttentionSignal(state: .finished, revision: 3, preview: "Done", at: Self.epoch))
        let inbox = ChatList.inbox(sessions: Self.connected([Agent(name: "zeus", status: .running), finished]), openAsks: state.openAsks, seen: state.seen)
        #expect(inbox.blocked.map(\.agent) == ["zeus"])
        #expect(inbox.finished.map(\.agent) == ["hera"])
        #expect(inbox.badge == .count(1))
    }

    @Test func aBlockedAgentsBriefStatusIsItsSecondaryLine() {
        let state = Self.listState(asks: [Self.ask("q1")])
        var zeus = Agent(name: "zeus", status: .running)
        zeus.brief = LeoAgentBrief(goal: "Migrate", status: "Waiting on your call")
        let inbox = ChatList.inbox(sessions: Self.connected([zeus]), openAsks: state.openAsks, seen: state.seen)
        #expect(inbox.blocked.first?.secondaryLine == "Waiting on your call")
    }

    @Test func aDisconnectedMachineAndStoppedAgentsDropOut() {
        let state = Self.listState(asks: [Self.ask("q1")])
        var sessions = Self.connected([Agent(name: "zeus", status: .running), Agent(name: "hera", status: .stopped, attention: .state(.needsInput, 1))])
        #expect(ChatList.inbox(sessions: sessions, openAsks: state.openAsks, seen: state.seen).blocked.map(\.agent) == ["zeus"])
        sessions[0].connection = .offline
        #expect(ChatList.inbox(sessions: sessions, openAsks: state.openAsks, seen: state.seen) == .empty)
    }

    @Test func answeringAnAskRemovesItsCard() async {
        let answered = Self.ask("q1", state: "answered")
        let store = TestStore(initialState: Self.listState(asks: [Self.ask("q1")])) { ChatList() } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.answer = { _, agent, id, answer in
                #expect((agent, id, answer.values) == ("zeus", "q1", ["y"]))
                return answered
            }
        }
        let answer = LeoChatAnswer(values: ["y"])
        await store.send(.askAnswered(daemonID: Self.daemon, agent: "zeus", messageID: "q1", answer)) { $0.answering = [LeoAgentID(host: Self.host, name: "zeus")] }
        await store.receive(\.askAnswerResponse) {
            $0.answering = []
            $0.openAsks.apply(host: Self.host, event: .updated(answered))
        }
        #expect(store.state.openAsks.threads.isEmpty)
    }

    @Test func anAskAnsweredElsewhereSettlesAndReloadsTheOpenSet() async {
        let store = TestStore(initialState: Self.listState(asks: [Self.ask("q1")])) { ChatList() } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.answer = { _, _, _, _ in throw LeoChatAnswerError.settled }
            $0.chatClient.openAsks = { _ in [] }
        }
        await store.send(.askAnswered(daemonID: Self.daemon, agent: "zeus", messageID: "q1", LeoChatAnswer(values: ["y"]))) {
            $0.answering = [LeoAgentID(host: Self.host, name: "zeus")]
        }
        await store.receive(\.askAnswerResponse) {
            $0.answering = []
            $0.eventsDuringSeed[Self.daemon] = []
        }
        await store.receive(\.openAsksResponse) {
            $0.eventsDuringSeed[Self.daemon] = nil
            $0.openAsks.seed(host: Self.host, messages: [], complete: true)
        }
        #expect(store.state.openAsks.threads.isEmpty)
        #expect(store.state.askErrors.isEmpty)
    }

    @Test func aRefusedAnswerKeepsTheCardAndShowsTheDaemonsReason() async {
        let store = TestStore(initialState: Self.listState(asks: [Self.ask("q1")])) { ChatList() } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.answer = { _, _, _, _ in throw LeoChatAnswerError.invalid("pick one") }
        }
        await store.send(.askAnswered(daemonID: Self.daemon, agent: "zeus", messageID: "q1", LeoChatAnswer(values: []))) {
            $0.answering = [LeoAgentID(host: Self.host, name: "zeus")]
        }
        await store.receive(\.askAnswerResponse) {
            $0.answering = []
            $0.askErrors[LeoAgentID(host: Self.host, name: "zeus")] = "pick one"
        }
        #expect(store.state.openAsks.threads.count == 1)
    }

    @Test func clearingMarksEveryFinishedItemSeenAndKeepsBlockedOnes() async {
        var seeded = Self.listState()
        seeded.seen.seed(host: Self.host, seen: [:])
        let agents = [
            Agent(name: "hera", status: .running, attention: LeoAttentionSignal(state: .finished, revision: 3, at: Self.epoch)),
            Agent(name: "zeus", status: .running, attention: .state(.needsInput, 2)),
        ]
        let items = ChatList.inbox(sessions: Self.connected(agents), openAsks: seeded.openAsks, seen: seeded.seen)
        var expected = seeded
        expected.seen.markSeen(LeoAgentID(host: Self.host, name: "hera"), at: Self.epoch, revision: 3, bootID: "boot", now: Self.epoch + 60)
        let saved = LockIsolated<[LeoInboxSeenState]>([])
        let store = TestStore(initialState: seeded) { ChatList() } withDependencies: {
            $0.date.now = Self.epoch + 60
            $0.inboxSeenStore.save = { state in saved.withValue { $0.append(state) } }
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.markSeen = { _, agents in Dictionary(uniqueKeysWithValues: agents.map { ($0, Self.epoch + 60) }) }
        }
        await store.send(.clearFinishedTapped(items.blocked + items.finished)) { $0.seen = expected.seen }
        await store.receive(\.seenResponse)
        let after = ChatList.inbox(sessions: Self.connected(agents), openAsks: store.state.openAsks, seen: store.state.seen)
        #expect(after.badge == .count(1))
        #expect(after.finished.allSatisfy { !$0.isUnread })
        #expect(saved.value.last == store.state.seen)
    }

    @Test func openingAnAgentSendsAMarkSeenToASyncedDaemon() async {
        var seeded = Self.listState()
        seeded.seen.seed(host: Self.host, seen: [:])
        let sent = LockIsolated<[String]>([])
        let store = TestStore(initialState: seeded) { ChatList() } withDependencies: {
            $0.date.now = Self.epoch
            $0.inboxSeenStore.save = { _ in }
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.markSeen = { _, agents in
                sent.withValue { $0 += agents }
                return ["zeus": Self.epoch]
            }
        }
        await store.send(.markSeen([SeenTarget(daemonID: Self.daemon, agent: "zeus")])) {
            $0.seen.markSeen(LeoAgentID(host: Self.host, name: "zeus"), at: nil, revision: nil, bootID: nil, now: Self.epoch)
        }
        await store.receive(\.seenResponse)
        #expect(sent.value == ["zeus"])
    }

    @Test func aDaemonWithoutTheSeenRouteKeepsTheMarkLocallyAndPersistsIt() async {
        var seeded = Self.listState()
        seeded.seen.seed(host: Self.host, seen: nil)
        let saved = LockIsolated<[LeoInboxSeenState]>([])
        let store = TestStore(initialState: seeded) { ChatList() } withDependencies: {
            $0.date.now = Self.epoch
            $0.inboxSeenStore.save = { state in saved.withValue { $0.append(state) } }
        }
        await store.send(.markSeen([SeenTarget(daemonID: Self.daemon, agent: "hera", at: Self.epoch, revision: 3, bootID: "boot")])) {
            $0.seen.markSeen(LeoAgentID(host: Self.host, name: "hera"), at: Self.epoch, revision: 3, bootID: "boot", now: Self.epoch)
        }
        #expect(saved.value.count == 1)
        #expect(!saved.value[0].isUnread(LeoAgentID(host: Self.host, name: "hera"), at: Self.epoch, revision: 3, bootID: "boot"))
    }

    @Test func anAgentSeenEventFromAnotherDeviceClearsTheItem() async {
        var seeded = Self.listState()
        seeded.seen.seed(host: Self.host, seen: [:])
        let store = TestStore(initialState: seeded) { ChatList() }
        await store.send(.agentSeen(Self.daemon, agent: "hera", seenAt: Self.epoch + 5)) {
            $0.seen.apply(host: Self.host, agent: "hera", seenAt: Self.epoch + 5)
        }
        #expect(!store.state.seen.isUnread(LeoAgentID(host: Self.host, name: "hera"), at: Self.epoch, revision: 1, bootID: nil))
    }

    @Test func aChatEventDuringTheOpenAsksLoadIsAppliedAfterIt() async {
        var seeded = Self.listState()
        seeded.eventsDuringSeed[Self.daemon] = []
        let store = TestStore(initialState: seeded) { ChatList() }
        store.exhaustivity = .off
        let late = Self.ask("q2")
        await store.send(.chatEvent(Self.daemon, .message(late), isOpen: false))
        await store.send(.openAsksResponse(Self.daemon, .success([])))
        #expect(store.state.openAsks.threads[LeoAgentID(host: Self.host, name: "zeus")]?.asks.map(\.id) == ["q2"])
    }

    @Test func aDaemonRestartMakesAFinishedItemUnreadAgainEvenAtTheSameRevision() {
        let agent = Agent(name: "hera", status: .running, attention: LeoAttentionSignal(state: .finished, revision: 3, at: Self.epoch))
        var seen = LeoInboxSeenState()
        seen.seed(host: Self.host, seen: nil)
        var sessions = Self.connected([agent])
        sessions[0].bootID = "boot-A"
        seen.markSeen(LeoAgentID(host: Self.host, name: "hera"), at: Self.epoch, revision: 3, bootID: "boot-A", now: Self.epoch)
        #expect(ChatList.inbox(sessions: sessions, openAsks: LeoOpenAsks(), seen: seen).finished.allSatisfy { !$0.isUnread })
        sessions[0].bootID = "boot-B"
        #expect(ChatList.inbox(sessions: sessions, openAsks: LeoOpenAsks(), seen: seen).finished.map(\.isUnread) == [true])
    }

    // MARK: Review round 1

    @Test func clearingStoresTheMarkUnderTheAgentNameNotItsDisplayName() async {
        var seeded = Self.listState()
        seeded.seen.seed(host: Self.host, seen: [:])
        var hera = Agent(name: "hera", status: .running, attention: LeoAttentionSignal(state: .finished, revision: 3, at: Self.epoch))
        hera.daemonDisplayName = "Hera Prime"
        let items = ChatList.inbox(sessions: Self.connected([hera]), openAsks: seeded.openAsks, seen: seeded.seen)
        #expect(items.finished.first?.agent == "Hera Prime")
        let store = TestStore(initialState: seeded) { ChatList() } withDependencies: {
            $0.date.now = Self.epoch + 60
            $0.inboxSeenStore.save = { _ in }
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.markSeen = { _, agents in
                #expect(agents == ["hera"])
                return ["hera": Self.epoch + 60]
            }
        }
        store.exhaustivity = .off
        await store.send(.clearFinishedTapped(items.finished))
        await store.skipReceivedActions()
        #expect(!store.state.seen.isUnread(LeoAgentID(host: Self.host, name: "hera"), at: Self.epoch, revision: 3, bootID: "boot"))
        #expect(items.finished.first?.agentRef == AgentRef(daemonID: Self.daemon, name: "hera"))
    }

    @Test func aSecondTapWhileAnAnswerIsInFlightIsIgnored() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let calls = LockIsolated(0)
        let answered = Self.ask("q1", state: "answered")
        let store = TestStore(initialState: Self.listState(asks: [Self.ask("q1")])) { ChatList() } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.chatClient.answer = { _, _, _, _ in
                calls.withValue { $0 += 1 }
                for await _ in gate { break }
                return answered
            }
        }
        let zeus = LeoAgentID(host: Self.host, name: "zeus")
        let answer = LeoChatAnswer(values: ["y"])
        await store.send(.askAnswered(daemonID: Self.daemon, agent: "zeus", messageID: "q1", answer)) { $0.answering = [zeus] }
        await store.send(.askAnswered(daemonID: Self.daemon, agent: "zeus", messageID: "q1", answer))
        release.yield()
        await store.receive(\.askAnswerResponse) {
            $0.answering = []
            $0.openAsks.apply(host: Self.host, event: .updated(answered))
        }
        #expect(calls.value == 1)
    }

    @Test func aDaemonWithoutTheOpenAsksRouteDropsAnswerdAsksAndReseedsFromThreads() async {
        var seeded = Self.listState(asks: [Self.ask("old", agent: "zeus")])
        seeded.threads[Self.daemon] = [
            LeoChatThread(agent: "zeus", lastMessage: Self.ask("old", agent: "zeus", state: "answered")),
            LeoChatThread(agent: "hera", lastMessage: Self.ask("new", agent: "hera")),
        ]
        let store = TestStore(initialState: seeded) { ChatList() }
        store.exhaustivity = .off
        await store.send(.openAsksResponse(Self.daemon, .success(nil)))
        let open = store.state.openAsks.threads
        #expect(open.keys.map(\.name) == ["hera"])
    }
}
