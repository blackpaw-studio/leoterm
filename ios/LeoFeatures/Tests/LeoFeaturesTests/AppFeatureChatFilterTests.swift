import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

/// The inbox's default chip: decided once, then only the user changes it.
@MainActor
struct AppFeatureChatFilterTests {
    static let daemon = PairedDaemon.dionysus.id

    static func state(_ agents: [Agent], connection: ConnectionStatus = .connected, hasLoadedDaemons: Bool = true) -> AppFeature.State {
        var state = AppFeature.State()
        state.hasLoadedDaemons = hasLoadedDaemons
        state.fleet = Fleet.State(daemons: [.dionysus])
        state.fleet.sessions[0].agents = IdentifiedArray(uniqueElements: agents)
        state.fleet.sessions[0].connection = connection
        return state
    }

    /// Any action runs the root's tail reducer, where the default is decided.
    static let tick = AppFeature.Action.chats(.threadRead(AgentRef(daemonID: daemon, name: "none")))

    static func asking(_ name: String = "zeus") -> Agent {
        Agent(name: name, status: .running, activity: .idle, attention: .state(.needsInput, 1))
    }

    @Test func defaultsToNeedsYouWhenSomethingNeedsYou() async {
        let store = TestStore(initialState: Self.state([Self.asking(), Agent(name: "hera", status: .running)])) { AppFeature() }
        await store.send(Self.tick) { $0.chats.filter = .needsYou }
    }

    @Test func defaultsToAllWhenNothingNeedsYou() async {
        let store = TestStore(initialState: Self.state([Agent(name: "hera", status: .running, activity: .working)])) { AppFeature() }
        await store.send(Self.tick) { $0.chats.filter = .all }
    }

    @Test func aNeedsYouAgentArrivingLaterDoesNotMoveADecidedChip() async {
        let store = TestStore(initialState: Self.state([Agent(name: "zeus", status: .running, activity: .idle)])) { AppFeature() }
        await store.send(Self.tick) { $0.chats.filter = .all }
        let event = LeoObserveEvent.agentActivity(seq: 2, at: nil, agent: "zeus", activity: .idle, currentAction: nil, attention: .state(.needsInput, 6))
        await store.send(\.fleet.eventReceived, (Self.daemon, event)) {
            $0.fleet.sessions[0].agents[id: "zeus"]?.attention = .state(.needsInput, 6)
        }
        #expect(store.state.chats.filter == .all)
    }

    @Test func thePickedChipSurvivesItsListEmptying() async {
        var state = Self.state([Self.asking()])
        state.chats.filter = .needsYou
        let store = TestStore(initialState: state) { AppFeature() }
        let event = LeoObserveEvent.agentActivity(seq: 2, at: nil, agent: "zeus", activity: .idle, currentAction: nil, attention: .state(.working, 6))
        await store.send(\.fleet.eventReceived, (Self.daemon, event)) {
            $0.fleet.sessions[0].agents[id: "zeus"]?.attention = .state(.working, 6)
        }
        #expect(store.state.chats.filter == .needsYou)
        await store.send(.chats(.filterPicked(.all))) { $0.chats.filter = .all }
    }

    @Test func nothingIsDecidedWhileADaemonIsStillConnecting() async {
        for connection in [ConnectionStatus.offline, .connecting] {
            let store = TestStore(initialState: Self.state([Self.asking()], connection: connection)) { AppFeature() }
            await store.send(Self.tick)
        }
        let unloaded = TestStore(initialState: Self.state([], hasLoadedDaemons: false)) { AppFeature() }
        await unloaded.send(Self.tick)
    }

    @Test func aDaemonThatCannotBeReachedDoesNotHoldTheDecisionBack() async {
        let store = TestStore(initialState: Self.state([], connection: .reconnecting(attempt: 1, reason: "down"))) { AppFeature() }
        await store.send(Self.tick) { $0.chats.filter = .all }
    }

    @Test func withNothingPairedTheChipIsAll() async {
        var state = AppFeature.State()
        state.hasLoadedDaemons = true
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(Self.tick) { $0.chats.filter = .all }
    }
}
