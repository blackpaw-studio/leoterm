import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct AppFeatureMoveTests {
    private static let ref = AgentRef(daemonID: PairedDaemon.dionysus.id, name: "zeus")

    private static func state(features: LeoDaemonFeatures = LeoDaemonFeatures(["agent_move"]), agent: Agent = Agent(.make("zeus"))) -> AppFeature.State {
        var state = AppFeature.State()
        state.fleet = Fleet.State(daemons: [.dionysus])
        state.fleet.sessions[0].agents = [agent]
        state.fleet.sessions[0].connection = .connected
        state.fleet.sessions[0].features = features
        return state
    }

    @Test func movingAnAgentOpensTheFlowOnItsDaemon() async {
        let store = TestStore(initialState: Self.state()) { AppFeature() }
        await store.send(.moveRequested(Self.ref, .move(to: "nas"))) {
            $0.move = AgentMove.State(daemon: .dionysus, agentName: "zeus", intent: .move(to: "nas"))
        }
    }

    @Test func aSecondRequestWhileAMoveIsInFlightChangesNothing() async {
        var initial = Self.state()
        initial.fleet.sessions[0].agents = [Agent(.make("zeus")), Agent(.make("hera"))]
        var flow = AgentMove.State(daemon: .dionysus, agentName: "zeus", intent: .move(to: "nas"))
        flow.isMoving = true
        flow.confirmation = nil
        initial.move = flow
        let store = TestStore(initialState: initial) { AppFeature() }
        await store.send(.moveRequested(AgentRef(daemonID: PairedDaemon.dionysus.id, name: "hera"), .move(to: "nas")))
    }

    @Test func replacingTheFlowCancelsTheOldMovesEffect() async {
        let gate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
        var initial = Self.state()
        initial.move = AgentMove.State(daemon: .dionysus, agentName: "zeus", intent: .move(to: "nas"))
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.move = { _, _, _ in
                await withCheckedContinuation { c in gate.setValue(c) }
                return .done(LeoMoveResult(name: "zeus", to: "nas"))
            }
        }
        store.exhaustivity = .off
        await store.send(\.move.presented.confirmation.presented.start, false)
        await store.send(\.move.presented.delegate.dismissed)
        #expect(store.state.move == nil)
        gate.value?.resume()
        await store.finish()
    }

    @Test func aDaemonWithoutAgentMoveIgnoresTheRequest() async {
        let store = TestStore(initialState: Self.state(features: .none)) { AppFeature() }
        await store.send(.moveRequested(Self.ref, .duplicate))
    }

    @Test func aMovedAgentCannotBeMovedAgain() async {
        var moved = Agent(.make("zeus", status: .stopped))
        moved.movedTo = "nas"
        let store = TestStore(initialState: Self.state(agent: moved)) { AppFeature() }
        await store.send(.moveRequested(Self.ref, .duplicate))
    }

    @Test func theDetailsMoveRowsOpenTheSameFlow() async {
        var initial = Self.state()
        initial.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
        initial.moveDestinations[PairedDaemon.dionysus.id] = .hosts(["nas"])
        initial.detail?.moves = .hosts(["nas"])
        let store = TestStore(initialState: initial) { AppFeature() }
        await store.send(\.detail.moveRequested, .copy(to: "nas")) {
            $0.move = AgentMove.State(daemon: .dionysus, agentName: "zeus", intent: .copy(to: "nas"))
        }
    }

    @Test func aFinishedMoveRefetchesTheFleetAndClosesTheFlow() async {
        var initial = Self.state()
        initial.move = AgentMove.State(daemon: .dionysus, agentName: "zeus", intent: .move(to: "nas"))
        let moved = LeoObservedAgent(
            name: "zeus", status: .stopped, activity: nil, currentAction: nil, lastActivityAt: nil,
            movedTo: "nas", movedAt: "2026-10-28T17:00:00Z"
        )
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.fetchState = { _ in LeoObservedState(agents: [moved]) }
        }
        await store.send(\.move.presented.delegate.completed) { $0.move = nil }
        await store.receive(\.fleet.snapshotLoaded) {
            $0.fleet.sessions[0].agents = [Agent(moved)]
        }
    }

    @Test func aFinishedMoveKeepsTheFlowWhileItsAlertIsUp() async {
        var initial = Self.state()
        var flow = AgentMove.State(daemon: .dionysus, agentName: "zeus", intent: .move(to: "nas"))
        flow.alert = AgentMove.failureAlert("Couldn't confirm the move of zeus", "gone")
        initial.move = flow
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.fetchState = { _ in LeoObservedState(agents: []) }
        }
        await store.send(\.move.presented.delegate.completed)
        await store.receive(\.fleet.snapshotLoaded) { $0.fleet.sessions[0].agents = [] }
        await store.send(\.move.presented.delegate.dismissed) { $0.move = nil }
    }

    @Test func aDaemonsHostsLoadWhenItConnectsAndFeedTheMenus() async {
        let store = TestStore(initialState: Self.state()) {
            AppFeature()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.moveHosts = { _ in .hosts(["nas", "work"]) }
        }
        store.exhaustivity = .off
        let id = PairedDaemon.dionysus.id
        await store.send(\.fleet.connected, (id, nil, LeoDaemonFeatures(["agent_move"]), LeoObservedState(agents: [.make("zeus")])))
        await store.receive(\.moveHostsLoaded)
        #expect(store.state.moveDestinations[id] == .hosts(["nas", "work"]))
        #expect(store.state.moveAvailability(for: id) == .hosts(["nas", "work"]))
    }

    @Test func menusDependOnWhatTheDaemonOffers() {
        let id = PairedDaemon.dionysus.id
        var state = Self.state()
        #expect(state.moveAvailability(for: id) == .duplicateOnly, "hosts not read yet: Duplicate is still possible")
        state.moveDestinations[id] = .unavailable
        #expect(state.moveAvailability(for: id) == .duplicateOnly)
        state.moveDestinations[id] = .hosts([])
        #expect(state.moveAvailability(for: id) == .duplicateOnly)
        state.moveDestinations[id] = .hosts(["nas"])
        #expect(state.moveAvailability(for: id) == .hosts(["nas"]))
        state.fleet.sessions[0].features = .none
        #expect(state.moveAvailability(for: id) == .unsupported)
    }
}
