import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct MachineSettingsTests {
    private static func link(
        _ connection: ConnectionStatus = .connected, features: [String] = ["config_api"], daemon: PairedDaemon = .dionysus
    ) -> MachineLink {
        var session = DaemonSession(daemon: daemon)
        session.connection = connection
        session.features = LeoDaemonFeatures(features)
        return MachineLink(session: session)
    }

    private static func store(
        _ state: MachineSettings.State, token: String? = "t"
    ) throws -> TestStore<MachineSettings.State, MachineSettings.Action> {
        let fake = try ConfigGolden.client()
        let store = TestStore(initialState: state) { MachineSettings() } withDependencies: {
            $0.secrets.load = { _ in token.map { DaemonSecrets(token: $0) } }
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in LeoConfigRevisionTracker() }
        }
        store.exhaustivity = .off
        return store
    }

    static let macOrder: [MachineSettings.Row] = [.templates, .tasks, .environments, .delegation, .defaults, .daemon]

    @Test func rowsInMacOrder() {
        let state = MachineSettings.State(link: Self.link())

        #expect(state.availability == .rows(Self.macOrder))
        #expect(MachineSettings.Row.defaults.title == "Defaults")
    }

    @Test func oldDaemonShowsRequires() {
        let state = MachineSettings.State(link: Self.link(features: []))

        #expect(state.availability == .requires("Requires leo ≥ 0.59.0"))
    }

    @Test func disconnectedShowsStatusNotRequires() {
        let reconnecting = ConnectionStatus.reconnecting(attempt: 2, reason: "timed out")

        #expect(MachineSettings.State(link: Self.link(reconnecting, features: [])).availability == .unavailable(reconnecting))
        #expect(MachineSettings.State(link: Self.link(.offline, features: ["config_api"])).availability == .unavailable(.offline))
    }

    @Test func rowTapPresentsPane() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        store.exhaustivity = .on

        let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        await store.send(.rowTapped(.templates)) {
            $0.restart.connection = connection
            $0.destination = .templates(ConfigCollection.State(resource: "templates", daemon: .dionysus, connection: connection))
        }
    }

    @Test func rowTapWithoutCredentialsAlertsInsteadOfOpening() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()), token: nil)

        await store.send(.rowTapped(.environments))

        #expect(store.state.destination == nil)
        #expect(store.state.alert != nil)
    }

    @Test func disconnectKeepsOpenPane() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.templates))

        await store.send(.linkUpdated(Self.link(.reconnecting(attempt: 1, reason: "dropped"), features: [])))

        #expect(store.state.destination?.templates != nil)
        #expect(store.state.availability == .rows(Self.macOrder))
        await store.receive(\.destination.presented.templates.machine.connectionChanged)
    }

    @Test func reconnectForwardsToPane() async throws {
        var state = MachineSettings.State(link: Self.link(.reconnecting(attempt: 1, reason: "dropped")))
        state.destination = .environments(ConfigCollection.State(
            resource: "environments", daemon: .dionysus, connection: DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        ))
        let store = try Self.store(state)

        await store.send(.linkUpdated(Self.link(.connected)))

        await store.receive(\.destination.presented.environments.machine.connectionChanged, true)
    }

    @Test func aChangeThatLeavesConnectivityAloneForwardsNothing() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.templates))

        await store.send(.linkUpdated(Self.link(.connected, features: ["config_api", "machine_stats"])))
    }

    @Test func theTasksRowOpensTheTasksPaneAndForwardsConnectivityToItsList() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))

        await store.send(.rowTapped(.tasks))
        #expect(store.state.destination?.tasks != nil)

        await store.send(.linkUpdated(Self.link(.offline, features: [])))
        await store.receive(\.destination.presented.tasks.collection.machine.connectionChanged, false)
    }

    @Test func aConfigPanesRestartBannerAsksTheMachineToRestart() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.templates))
        await store.send(.destination(.presented(.templates(.task))))
        await store.receive(\.destination.presented.templates.loaded)
        await store.send(.destination(.presented(.templates(.rowTapped("coder")))))
        await store.send(.destination(.presented(.templates(.field("model", .string("sonnet"))))))
        await store.send(.destination(.presented(.templates(.saveTapped))))
        await store.receive(\.destination.presented.templates.writeFinished)

        await store.send(.destination(.presented(.templates(.restartBannerTapped(.agents)))))
        await store.receive(\.destination.presented.templates.delegate.restart, .agents)
        await store.receive(\.restart.requested, .agents)
        await store.receive(\.restart.statusChecked)

        #expect(store.state.restart.alert != nil)
        #expect(store.state.restart.machine == PairedDaemon.dionysus.name)
    }

    // MARK: delegation

    @Test func theDelegationRowOpensDelegation() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))

        await store.send(.rowTapped(.delegation))

        #expect(store.state.destination?.delegation != nil)
        #expect(MachineSettings.Row.delegation.title == "Delegation")
    }

    @Test func delegationRestartAsksTheMachine() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.delegation))

        await store.send(.destination(.presented(.delegation(.delegate(.restart(.agents))))))

        await store.receive(\.restart.requested, .agents)
    }

    @Test func connectionForwardsToDelegation() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.delegation))

        await store.send(.linkUpdated(Self.link(.offline, features: [])))

        await store.receive(\.destination.presented.delegation.machine.connectionChanged, false)
        #expect(store.state.destination?.delegation?.isMachineConnected == false)
    }

    // MARK: daemon

    @Test func daemonOpensOnServiceFirst() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))

        await store.send(.rowTapped(.daemon))

        let daemon = try #require(store.state.destination?.daemon)
        #expect(daemon.sections.first == .service)
        #expect(daemon.destination == nil)
        #expect(MachineSettings.Row.daemon.title == "Daemon")
    }

    @Test func restartFinishedRefreshesServiceInsideDaemon() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.daemon))
        await store.send(.destination(.presented(.daemon(.sectionTapped(.service)))))

        await store.send(.restart(.delegate(.finished)))

        await store.receive(\.destination.presented.daemon.machine.restartFinished)
        await store.receive(\.destination.presented.daemon.destination.presented.service.refreshRequested)
    }

    @Test func connectionForwardsIntoDaemonChild() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.daemon))
        await store.send(.destination(.presented(.daemon(.sectionTapped(.client)))))

        await store.send(.linkUpdated(Self.link(.offline, features: [])))

        await store.receive(\.destination.presented.daemon.machine.connectionChanged, false)
        await store.receive(\.destination.presented.daemon.destination.presented.client.machine.connectionChanged, false)
        #expect(store.state.destination?.daemon?.destination?.client != nil)
    }

    @Test func aDaemonChildsRestartAsksTheMachine() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.daemon))

        await store.send(.destination(.presented(.daemon(.delegate(.restart(.daemon))))))

        await store.receive(\.restart.requested, .daemon)
    }

    @Test func theScenePhaseReachesTheServiceInsideDaemon() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.daemon))
        await store.send(.destination(.presented(.daemon(.sectionTapped(.service)))))

        await store.send(.scenePhaseChanged(isActive: false))

        await store.receive(\.destination.presented.daemon.machine.scenePhaseChanged, false)
    }

    // MARK: defaults

    @Test func theDefaultsRowOpensTheDefaultsForm() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))

        await store.send(.rowTapped(.defaults))

        #expect(store.state.destination?.defaults?.core.resourceKey == "defaults")
    }

    @Test func theDefaultsFormsRestartAsksTheMachine() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.defaults))

        await store.send(.destination(.presented(.defaults(.delegate(.restart(.agents))))))

        await store.receive(\.restart.requested, .agents)
    }

    @Test func leavingTheDefaultsFormClosesIt() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.defaults))

        await store.send(.destination(.presented(.defaults(.delegate(.leave)))))

        #expect(store.state.destination == nil)
    }

    @Test func connectivityReachesAnOpenDefaultsForm() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))
        await store.send(.rowTapped(.defaults))

        await store.send(.linkUpdated(Self.link(.offline, features: [])))

        await store.receive(\.destination.presented.defaults.machine.connectionChanged, false)
    }

    @Test func theScenePhaseReachesTheMachineRestart() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link()))

        await store.send(.scenePhaseChanged(isActive: false))

        await store.receive(\.restart.scenePhaseChanged, false)
    }

    @Test func reconnectTapAsksTheFleetToRetry() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link(.offline)))

        await store.send(.reconnectTapped)

        await store.receive(\.delegate.retry, PairedDaemon.dionysus.id)
    }
}
