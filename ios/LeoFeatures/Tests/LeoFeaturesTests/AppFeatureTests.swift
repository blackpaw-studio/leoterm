import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct AppFeatureTests {
    @Test func forgettingADaemonConfirmsThenRemovesItAndItsSecrets() async {
        let deleted = LockIsolated<[String]>([])
        let saved = LockIsolated<[[PairedDaemon]]>([])
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus, .hestia])
        initial.fleet.sessions[0].agents = [Agent(name: "zeus")]
        initial.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(name: "zeus"), connection: .offline)
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.secrets.delete = { id in deleted.withValue { $0.append(id) } }
            $0.pairedDaemons.save = { daemons in saved.withValue { $0.append(daemons) } }
        }
        await store.send(\.daemons.forgetButtonTapped, .dionysus) {
            $0.daemons.alert = Daemons.forgetAlert(.dionysus)
        }
        await store.send(\.daemons.alert.presented.confirmForget, PairedDaemon.dionysus.id) {
            $0.daemons.alert = nil
        }
        await store.receive(\.daemons.delegate.forget) {
            $0.fleet.sessions.remove(id: PairedDaemon.dionysus.id)
            $0.detail = nil
        }
        #expect(deleted.value == [PairedDaemon.dionysus.id])
        #expect(saved.value == [[.hestia]])
    }

    @Test func pairingAddsTheDaemonAndClosesTheSheet() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.pairedDaemons.save = { _ in }
        }
        await store.send(.pairButtonTapped) { $0.pairing = Pairing.State() }
        await store.send(\.pairing.delegate.paired, .hestia) {
            $0.pairing = nil
            $0.fleet.sessions = [DaemonSession(daemon: .hestia)]
        }
    }

    @Test func theDaemonsScreenAddButtonOpensPairing() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(\.daemons.addButtonTapped)
        await store.receive(\.daemons.delegate.add) { $0.pairing = Pairing.State() }
    }

    @Test func selectingAnAgentShowsItsLiveDetail() async {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.fleet.sessions[0].agents = [Agent(.make("zeus"))]
        initial.fleet.sessions[0].connection = .connected
        let store = TestStore(initialState: initial) { AppFeature() }

        await store.send(.agentTapped(AgentRef(daemonID: PairedDaemon.dionysus.id, name: "zeus"))) {
            $0.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
        }
        // A live update reaches the open detail.
        await store.send(\.fleet.eventReceived, (PairedDaemon.dionysus.id, .agentStopped(seq: 2, at: nil, agent: "zeus", wakeOnMessage: false))) {
            $0.fleet.sessions[0].agents[id: "zeus"]?.status = .stopped
            $0.fleet.sessions[0].agents[id: "zeus"]?.activity = .unknown
            $0.detail?.agent?.status = .stopped
            $0.detail?.agent?.activity = .unknown
        }
    }

    @Test func tappingAnUnknownAgentDoesNothing() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.agentTapped(AgentRef(daemonID: "nope", name: "zeus")))
    }

    @Test func scenePhaseDrivesTheConnections() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.scenePhaseChanged(isActive: true)) { $0.fleet.isActive = true }
        await store.send(.scenePhaseChanged(isActive: false)) { $0.fleet.isActive = false }
    }
}
