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
            // No saved token: nothing to unregister push with.
            $0.secrets.load = { _ in nil }
            $0.pushClient.sharePairedDaemons = { _ in }
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

    @Test func aResponseForThePreviousAgentDoesNotReachTheNewSelection() async {
        let clock = TestClock()
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.fleet.sessions[0].agents = [Agent(.make("zeus")), Agent(.make("hera"))]
        initial.fleet.sessions[0].connection = .connected
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.environmentNames = { _ in
                try await clock.sleep(for: .seconds(1))
                return ["work"]
            }
        }
        let id = PairedDaemon.dionysus.id

        await store.send(.agentTapped(AgentRef(daemonID: id, name: "zeus"))) {
            $0.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
        }
        await store.send(\.detail.switchEnvironmentButtonTapped) { $0.detail?.isLoadingEnvironments = true }
        await store.send(.agentTapped(AgentRef(daemonID: id, name: "hera"))) {
            $0.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("hera")), connection: .connected)
        }
        // Replacing the selection cancels zeus's request: its catalog must
        // not open a picker that would restart hera.
        await clock.advance(by: .seconds(1))
        await store.finish()
        #expect(store.state.detail?.confirmation == nil)
    }

    @Test func tappingAnUnknownAgentDoesNothing() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.agentTapped(AgentRef(daemonID: "nope", name: "zeus")))
    }

    @Test func scenePhaseDrivesTheConnections() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.pushClient = .granted
            $0.pushCleanup = .inMemory(LockIsolated([:]))
        }
        await store.send(.scenePhaseChanged(isActive: true)) { $0.fleet.isActive = true }
        await store.receive(\.push.authorizationRefreshed) { $0.push.authorization = .authorized }
        await store.send(.scenePhaseChanged(isActive: false)) { $0.fleet.isActive = false }
    }

    @Test func machineLinkStaysInSyncWithTheFleet() async {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.fleet.isActive = true
        initial.fleet.sessions[0].connection = .connected
        initial.fleet.sessions[0].features = LeoDaemonFeatures(["config_api"])
        initial.daemons.machine = MachineSettings.State(link: MachineLink(session: initial.fleet.sessions[0]))
        let store = TestStore(initialState: initial) { AppFeature() }
        store.exhaustivity = .off

        await store.send(.scenePhaseChanged(isActive: false))

        await store.receive(\.daemons.machine.presented.linkUpdated)
        #expect(store.state.daemons.machine?.link.connection == .offline)
    }

    @Test func tappingAMachineOpensItsSettings() async {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.fleet.sessions[0].connection = .connected
        let store = TestStore(initialState: initial) { AppFeature() }
        store.exhaustivity = .off

        await store.send(.daemons(.machineTapped(PairedDaemon.dionysus.id)))

        await store.receive(\.daemons.delegate.openMachine)
        #expect(store.state.daemons.machine?.id == PairedDaemon.dionysus.id)
    }

    /// A machine left in `daemons.machine` after the Machines screen is gone
    /// makes the next tap on its row a no-op: the navigation sees the same
    /// item already presented and pushes nothing.
    @Test func leavingTheMachinesScreenClosesTheOpenMachine() async {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.isShowingDaemons = true
        initial.daemons.machine = MachineSettings.State(link: MachineLink(session: initial.fleet.sessions[0]))
        let store = TestStore(initialState: initial) { AppFeature() }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.isShowingDaemons, false)))

        #expect(store.state.daemons.machine == nil)
    }

    @Test func forgettingTheOpenMachineClosesItsSettings() async {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.daemons.machine = MachineSettings.State(link: MachineLink(session: initial.fleet.sessions[0]))
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.secrets.delete = { _ in }
            $0.secrets.load = { _ in nil }
            $0.pushClient.sharePairedDaemons = { _ in }
            $0.pairedDaemons.save = { _ in }
        }
        store.exhaustivity = .off

        await store.send(\.daemons.forgetButtonTapped, .dionysus)
        await store.send(\.daemons.alert.presented.confirmForget, PairedDaemon.dionysus.id)
        await store.receive(\.daemons.delegate.forget)

        #expect(store.state.daemons.machine == nil)
    }

    // MARK: settings lifecycle

    private static func machineOpen(destination: (MachineSettings.State, DaemonConnection) -> MachineSettings.Destination.State?) -> AppFeature.State {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.fleet.sessions[0].connection = .connected
        initial.fleet.sessions[0].features = LeoDaemonFeatures(["config_api"])
        var machine = MachineSettings.State(link: MachineLink(session: initial.fleet.sessions[0]))
        let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        machine.destination = destination(machine, connection)
        initial.daemons.machine = machine
        return initial
    }

    /// Coming to the foreground rechecks push and reconnects: none of it is under test here.
    private static func quietAppDependencies(_ dependencies: inout DependencyValues) {
        dependencies.pushClient = .granted
        dependencies.pushCleanup = .inMemory(LockIsolated([:]))
        dependencies.secrets.load = { _ in nil }
        dependencies.continuousClock = TestClock()
    }

    @Test func backgroundForwardsToServicePane() async {
        let initial = Self.machineOpen { _, connection in .service(ServiceSettings.State(daemon: .dionysus, connection: connection)) }
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.configClients.client = { _ in LeoFakeConfigClient(schema: LeoConfigSchema(resources: [])) }
            Self.quietAppDependencies(&$0)
        }
        store.exhaustivity = .off

        await store.send(.scenePhaseChanged(isActive: false))
        await store.receive(\.daemons.machine.presented.scenePhaseChanged)
        await store.receive(\.daemons.machine.presented.destination.presented.service.machine.scenePhaseChanged)
        #expect(store.state.daemons.machine?.destination?.service?.isActive == false)

        await store.send(.scenePhaseChanged(isActive: true))
        await store.receive(\.daemons.machine.presented.destination.presented.service.machine.scenePhaseChanged)
        #expect(store.state.daemons.machine?.destination?.service?.isActive == true)
    }

    @Test func foregroundReconnectRebasesOpenDraft() async throws {
        let fake = try ConfigGolden.client()
        var initial = Self.machineOpen { _, connection in
            .templates(ConfigCollection.State(resource: "templates", daemon: .dionysus, connection: connection))
        }
        // The app comes back with the machine not yet reconnected.
        initial.fleet.sessions[0].connection = .offline
        initial.daemons.machine?.link.connection = .offline
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in LeoConfigRevisionTracker() }
            Self.quietAppDependencies(&$0)
        }
        store.exhaustivity = .off
        await store.send(.daemons(.machine(.presented(.destination(.presented(.templates(.task)))))))
        await store.receive(\.daemons.machine.presented.destination.presented.templates.loaded)
        await store.send(.daemons(.machine(.presented(.destination(.presented(.templates(.rowTapped("coder"))))))))
        await store.send(.daemons(.machine(.presented(.destination(.presented(.templates(.field("model", .string("sonnet")))))))))

        // Backgrounded, another writer changes the file, then the app returns and the fleet reconnects.
        await store.send(.scenePhaseChanged(isActive: false))
        await fake.externalChange("templates", name: "coder", values: ["workspace": .string("/tmp/theirs")])
        await store.send(.scenePhaseChanged(isActive: true))
        await store.send(\.fleet.connected, (PairedDaemon.dionysus.id, bootID: "b1", features: LeoDaemonFeatures(["config_api"]), LeoObservedState(agents: [])))
        await store.receive(\.daemons.machine.presented.linkUpdated)
        await store.receive(\.daemons.machine.presented.destination.presented.templates.machine.connectionChanged, true)
        await store.receive(\.daemons.machine.presented.destination.presented.templates.refreshed)

        let pane = try #require(store.state.daemons.machine?.destination?.templates)
        #expect(pane.core.isDirty)
        #expect(pane.core.draft?.value(at: "model") == .string("sonnet"))
        #expect(pane.core.draft?.value(at: "workspace") == .string("/tmp/theirs"))
    }
}
