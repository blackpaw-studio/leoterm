import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

extension PushClient {
    /// Permission already granted; a token request goes nowhere.
    static let granted = PushClient(
        authorization: { .authorized }, requestAuthorization: { true }, registerForRemoteNotifications: {}, key: { .fixture },
        sharePairedDaemons: { _ in }
    )
}

@MainActor
struct AppFeaturePushTests {
    static let zeus = AgentRef(daemonID: PairedDaemon.dionysus.id, name: "zeus")

    @Test func pairingRegistersTheNewDaemonForPushes() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.pairedDaemons.save = { _ in }
            $0.pushClient = .granted
        }
        await store.send(.pairButtonTapped) { $0.pairing = Pairing.State() }
        await store.send(\.pairing.delegate.paired, .hestia) {
            $0.pairing = nil
            $0.fleet.sessions = [DaemonSession(daemon: .hestia)]
            $0.push.daemons = [.hestia]
        }
        await store.receive(\.push.authorizationChanged, .authorized) { $0.push.authorization = .authorized }
    }

    @Test func forgettingKeepsTheTokenForPushCleanupBeforeDeletingIt() async {
        let log = LockIsolated<[String]>([])
        let records = LockIsolated<[String: ForgottenDaemon]>([:])
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.push.daemons = [.dionysus]
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.secrets.delete = { id in log.withValue { $0.append("delete \(id)") } }
            $0.pairedDaemons.save = { _ in }
            $0.pushClient = .granted
            $0.pushCleanup = PushCleanupClient(
                load: { Array(records.value.values) },
                save: { record in
                    log.withValue { $0.append("record \(record.id)") }
                    records.withValue { $0[record.id] = record }
                },
                remove: { id in records.withValue { $0[id] = nil } }
            )
            $0.daemonClient.deletePush = { _, _ in throw LeoDaemonError.transport("offline") }
        }
        // Gone from the UI at once, whatever the daemon says.
        await store.send(\.daemons.delegate.forget, PairedDaemon.dionysus.id) {
            $0.fleet.sessions = []
            $0.push.daemons = []
        }
        await store.receive(\.push.cleanupRecorded)
        await store.finish()
        #expect(log.value == ["record dev-1", "delete d-dionysus"])
        #expect(records.value["dev-1"]?.secrets == DaemonSecrets(token: "t"))
    }

    @Test func comingToTheForegroundRechecksPush() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.pushClient = .granted
            $0.pushCleanup = .inMemory(LockIsolated([:]))
        }
        await store.send(.scenePhaseChanged(isActive: true)) { $0.fleet.isActive = true }
        await store.receive(\.push.authorizationRefreshed, .authorized) { $0.push.authorization = .authorized }
    }

    @Test func aReconnectFinishesThatDaemonsPendingTurnOff() async {
        let deletes = LockIsolated<[String]>([])
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.push.daemons = [.dionysus]
        initial.push.$isEnabled.withLock { $0 = false }
        initial.push.$pendingUnregister.withLock { $0 = ["d-dionysus"] }
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.deletePush = { _, deviceID in deletes.withValue { $0.append(deviceID) } }
        }
        await store.send(\.fleet.connected, (PairedDaemon.dionysus.id, bootID: "b1", LeoObservedState(agents: []))) {
            $0.fleet.sessions[0].connection = .connected
            $0.fleet.sessions[0].bootID = "b1"
        }
        await store.receive(\.push.unregistered) { $0.push.$pendingUnregister.withLock { $0 = [] } }
        #expect(deletes.value == ["dev-1"])
    }

    // MARK: Deep links

    @Test func aTapWhileRunningOpensTheAgent() async {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.fleet.sessions[0].agents = [Agent(.make("zeus"))]
        initial.fleet.sessions[0].connection = .connected
        initial.hasLoadedDaemons = true
        let store = TestStore(initialState: initial) { AppFeature() }

        await store.send(.notificationOpened(Self.zeus)) {
            $0.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
        }
    }

    @Test func aTapThatLaunchedTheAppOpensTheAgentOnceItLoads() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.pushClient = .granted
            $0.pushCleanup = .inMemory(LockIsolated([:]))
        }
        let id = PairedDaemon.dionysus.id

        await store.send(.notificationOpened(Self.zeus)) { $0.pendingAgent = Self.zeus }
        await store.send(\.fleet.daemonsLoaded, ([.dionysus], seen: LeoSurfacedFileLedger())) {
            $0.fleet.sessions = [DaemonSession(daemon: .dionysus)]
            $0.hasLoadedDaemons = true
            $0.push.daemons = [.dionysus]
        }
        await store.receive(\.push.authorizationChanged, .authorized) { $0.push.authorization = .authorized }
        await store.send(\.fleet.connected, (id, bootID: "b1", LeoObservedState(agents: [.make("zeus")]))) {
            $0.fleet.sessions[0].connection = .connected
            $0.fleet.sessions[0].bootID = "b1"
            $0.fleet.sessions[0].agents = [Agent(.make("zeus"))]
            $0.pendingAgent = nil
            $0.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(.make("zeus")), connection: .connected)
        }
    }

    @Test func aTapForAnUnpairedDaemonIsDropped() async {
        var initial = AppFeature.State()
        initial.hasLoadedDaemons = true
        let store = TestStore(initialState: initial) { AppFeature() }

        await store.send(.notificationOpened(Self.zeus))
    }

    @Test func aTapForAnAgentTheDaemonNoLongerHasIsDropped() async {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.hasLoadedDaemons = true
        let store = TestStore(initialState: initial) { AppFeature() }
        let id = PairedDaemon.dionysus.id

        await store.send(.notificationOpened(Self.zeus)) { $0.pendingAgent = Self.zeus }
        await store.send(\.fleet.connected, (id, bootID: "b1", LeoObservedState(agents: [.make("hera")]))) {
            $0.fleet.sessions[0].connection = .connected
            $0.fleet.sessions[0].bootID = "b1"
            $0.fleet.sessions[0].agents = [Agent(.make("hera"))]
            $0.pendingAgent = nil
        }
    }

    @Test func choosingAnotherAgentCancelsAPendingTap() async {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus, .hestia])
        initial.fleet.sessions[1].agents = [Agent(.make("hera"))]
        initial.fleet.sessions[1].connection = .connected
        initial.hasLoadedDaemons = true
        let store = TestStore(initialState: initial) { AppFeature() }

        await store.send(.notificationOpened(Self.zeus)) { $0.pendingAgent = Self.zeus }
        await store.send(.agentTapped(AgentRef(daemonID: PairedDaemon.hestia.id, name: "hera"))) {
            $0.pendingAgent = nil
            $0.detail = AgentDetail.State(daemon: .hestia, agent: Agent(.make("hera")), connection: .connected)
        }
    }

    @Test func theSettingsButtonShowsSettings() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.settingsButtonTapped) { $0.isShowingSettings = true }
    }
}
