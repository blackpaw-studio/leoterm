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

    @Test func rowsNeedConfigAPI() {
        let state = MachineSettings.State(link: Self.link())

        #expect(state.availability == .rows([.templates, .environments, .tasks]))
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

        await store.send(.rowTapped(.templates)) {
            $0.destination = .templates(ConfigCollection.State(
                resource: "templates", daemon: .dionysus, connection: DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
            ))
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
        #expect(store.state.availability == .rows([.templates, .environments, .tasks]))
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

    @Test func reconnectTapAsksTheFleetToRetry() async throws {
        let store = try Self.store(MachineSettings.State(link: Self.link(.offline)))

        await store.send(.reconnectTapped)

        await store.receive(\.delegate.retry, PairedDaemon.dionysus.id)
    }
}
