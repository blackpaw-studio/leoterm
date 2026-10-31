import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

/// The live terminal strip under a chat thread: when it connects, and which
/// bus it uses.
@MainActor
struct TerminalStripTests {
    let streams = Streams<LeoTerminalEvent>(count: 4)
    let stripBus = TerminalOutputBus()
    let fullBus = TerminalOutputBus()
    let zeus = AgentRef(daemonID: PairedDaemon.dionysus.id, name: "zeus")

    /// An app with zeus's thread open and on screen.
    func makeStore(
        agent: Agent? = Agent(.make("zeus")), showsByDefault: Bool = true, isOnScreen: Bool = true
    ) -> TestStoreOf<AppFeature> {
        @Shared(.showsTerminalInChats) var showsTerminalInChats
        $showsTerminalInChats.withLock { $0 = showsByDefault }
        var state = AppFeature.State()
        state.fleet = Fleet.State(daemons: [.dionysus])
        state.fleet.sessions[0].agents = agent.map { [$0] } ?? []
        state.fleet.sessions[0].connection = .connected
        state.hasLoadedDaemons = true
        state.chats.filter = .all
        state.chat = ChatThread.State(daemon: .dionysus, agent: "zeus", live: agent)
        state.chat?.isOnScreen = isOnScreen
        let (streams, stripBus, fullBus) = (streams, stripBus, fullBus)
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.terminalClient.attach = { _, _, _ in streams.next() }
            $0.terminalStripOutput = stripBus
            $0.terminalOutput = fullBus
            $0.chatClient.markRead = { _, _, _ in }
            // Coming back to the foreground wakes the rest of the app, too.
            $0.pushClient = .granted
            $0.pushCleanup = .inMemory(LockIsolated([:]))
            $0.daemonClient.events = { _ in AsyncThrowingStream { _ in } }
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off
        return store
    }

    /// Any action runs the root's tail reducer, where the strip is kept in step.
    static let tick = AppFeature.Action.chats(.threadRead(AgentRef(daemonID: PairedDaemon.dionysus.id, name: "none")))

    @Test func aNewThreadStartsFromTheSetting() {
        for value in [true, false] {
            let store = makeStore(showsByDefault: value)
            #expect(store.state.chat?.strip.isShown == value)
            #expect(store.state.chat?.strip.userChoice == nil)
        }
    }

    @Test func connectsOnceTheThreadIsOnScreenAndTheStripShown() async {
        let store = makeStore()
        await store.send(Self.tick)
        #expect(store.state.chat?.strip.terminal.isVisible == true)
        #expect(store.state.chat?.strip.terminal.phase == .connecting)
        streams[0].yield(.opened)
        await store.receive(\.chat.strip.terminal.opened)
        #expect(store.state.chat?.strip.terminal.phase == .live)
        #expect(streams.opened.value == 1)
    }

    @Test func doesNotConnectOffScreenOrWhenHiddenByTheSetting() async {
        let offScreen = makeStore(isOnScreen: false)
        await offScreen.send(Self.tick)
        let hidden = makeStore(showsByDefault: false)
        await hidden.send(Self.tick)
        #expect(offScreen.state.chat?.strip.terminal.isVisible == false)
        #expect(hidden.state.chat?.strip.terminal.isVisible == false)
        #expect(streams.opened.value == 0)
    }

    @Test func noConnectionWhenTheAgentIsNotInTheFleet() async {
        let store = makeStore(agent: nil)
        await store.send(Self.tick)
        #expect(store.state.chat?.strip.terminal.isVisible == false)
        #expect(streams.opened.value == 0)
    }

    @Test func hidingTheStripClosesItAndShowingItReconnects() async {
        let store = makeStore()
        await store.send(Self.tick)
        streams[0].yield(.opened)
        await store.receive(\.chat.strip.terminal.opened)

        await store.send(.chat(.strip(.toggleTapped)))
        #expect(store.state.chat?.strip.userChoice == false)
        #expect(store.state.chat?.strip.terminal.phase == .idle)
        #expect(streams.terminated.value == 1)

        await store.send(.chat(.strip(.toggleTapped)))
        #expect(store.state.chat?.strip.userChoice == true)
        #expect(store.state.chat?.strip.terminal.phase == .connecting)
    }

    @Test func leavingTheScreenClosesTheStrip() async {
        let store = makeStore()
        await store.send(Self.tick)
        await store.send(.chat(.onScreenChanged(false)))
        #expect(store.state.chat?.strip.terminal.phase == .idle)
        #expect(store.state.chat?.strip.terminal.isVisible == false)
        await store.send(.chat(.onScreenChanged(true)))
        #expect(store.state.chat?.strip.terminal.phase == .connecting)
    }

    @Test func backgroundingClosesTheStripAndReturningReconnects() async {
        let store = makeStore()
        await store.send(Self.tick)
        await store.send(.scenePhaseChanged(isActive: false))
        #expect(store.state.chat?.strip.terminal.phase == .paused)
        #expect(streams.terminated.value == 1)
        await store.send(.scenePhaseChanged(isActive: true))
        #expect(store.state.chat?.strip.terminal.phase == .connecting)
        #expect(streams.opened.value == 2)
    }

    @Test func aSettingFlipAppliesToAnUntoggledOpenThreadButNotToAToggledOne() async {
        let untoggled = makeStore()
        await untoggled.send(Self.tick)
        #expect(untoggled.state.chat?.strip.terminal.isVisible == true)
        await untoggled.send(.showsTerminalInChatsToggled(false))
        #expect(untoggled.state.chat?.strip.isShown == false)
        #expect(untoggled.state.chat?.strip.terminal.phase == .idle)

        let toggled = makeStore()
        await toggled.send(Self.tick)
        await toggled.send(.chat(.strip(.toggleTapped)))
        await toggled.send(.chat(.strip(.toggleTapped)))
        await toggled.send(.showsTerminalInChatsToggled(false))
        #expect(toggled.state.chat?.strip.isShown == true)
        #expect(toggled.state.chat?.strip.terminal.isVisible == true)
    }

    @Test func aReopenedThreadResetsTheToggle() async {
        let store = makeStore()
        await store.send(.chat(.strip(.toggleTapped)))
        #expect(store.state.chat?.strip.userChoice == false)
        await store.send(.chatPopped)
        await store.send(.chatOpened(zeus))
        #expect(store.state.chat?.strip.userChoice == nil)
        #expect(store.state.chat?.strip.isShown == true)
    }

    @Test func theAgentStoppingShowsNotRunning() async {
        let store = makeStore()
        await store.send(Self.tick)
        await store.send(\.fleet.eventReceived, (zeus.daemonID, .agentStopped(seq: 2, at: nil, agent: "zeus", wakeOnMessage: false)))
        #expect(store.state.chat?.strip.terminal.phase == .notRunning)
    }

    @Test func theStripUsesItsOwnBusSoTheFullTerminalCanWatchTheSameAgent() async {
        let stripOutput = stripBus.output(for: zeus)
        let fullOutput = fullBus.output(for: zeus)
        let store = makeStore()
        await store.send(Self.tick)
        streams[0].yield(.opened)
        await store.receive(\.chat.strip.terminal.opened)
        var strip = stripOutput.makeAsyncIterator()
        #expect(await strip.next() == .reset)
        streams[0].yield(.output(Data("x".utf8)))
        #expect(await strip.next() == .bytes(Data("x".utf8)))
        // The full terminal's bus saw none of it.
        fullBus.send(.bytes(Data("only-full".utf8)), to: zeus)
        var full = fullOutput.makeAsyncIterator()
        #expect(await full.next() == .bytes(Data("only-full".utf8)))
    }
}
