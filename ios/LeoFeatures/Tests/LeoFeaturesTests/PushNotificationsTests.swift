import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

/// Records every relay and daemon call a push test makes.
final class PushRecorder: Sendable {
    let relay = LockIsolated<[Data]>([])
    let puts = LockIsolated<[String]>([])
    let deletes = LockIsolated<[String]>([])
    let registrations = LockIsolated<[LeoPushRegistration]>([])
    let prompts = LockIsolated(0)
    let apnsRequests = LockIsolated(0)
    let apnsUnregistrations = LockIsolated(0)
    let shared = LockIsolated<[Set<String>]>([])
    let cleanup = LockIsolated<[String: ForgottenDaemon]>([:])
}

extension PushCleanupClient {
    /// Backed by `records`, keyed by device ID like the Keychain one.
    static func inMemory(_ records: LockIsolated<[String: ForgottenDaemon]>) -> Self {
        PushCleanupClient(
            load: { Array(records.value.values) },
            save: { record in records.withValue { $0[record.id] = record } },
            remove: { id in records.withValue { $0[id] = nil } }
        )
    }
}

extension LeoPushKey {
    static let fixture = LeoPushKey(data: Data(repeating: 7, count: 32))!
}

@MainActor
struct PushNotificationsTests {
    static let relayURL = URL(string: "https://leo-relay.test.workers.dev")!
    static let tokenA = Data([0xAA, 0x01])
    static let tokenB = Data([0xBB, 0x02])

    static func store(
        _ state: PushNotifications.State = PushNotifications.State(),
        authorization: PushAuthorization = .authorized,
        grant: Bool = true,
        recorder: PushRecorder,
        relay: (@Sendable (Data) async throws -> String)? = nil,
        daemon: (@Sendable (String) async throws -> Void)? = nil
    ) -> TestStoreOf<PushNotifications> {
        TestStore(initialState: state) {
            PushNotifications()
        } withDependencies: {
            $0.pushConfiguration = PushConfiguration(relayURL: relayURL, environment: .sandbox)
            $0.pushClient.authorization = { authorization }
            $0.pushClient.requestAuthorization = {
                recorder.prompts.withValue { $0 += 1 }
                return grant
            }
            $0.pushClient.registerForRemoteNotifications = { recorder.apnsRequests.withValue { $0 += 1 } }
            $0.pushClient.unregisterForRemoteNotifications = { recorder.apnsUnregistrations.withValue { $0 += 1 } }
            $0.pushClient.key = { .fixture }
            $0.pushClient.sharePairedDaemons = { ids in recorder.shared.withValue { $0.append(ids) } }
            $0.pushCleanup = .inMemory(recorder.cleanup)
            $0.pushRelay.register = { url, token, environment in
                #expect(url == relayURL)
                #expect(environment == .sandbox)
                recorder.relay.withValue { $0.append(token) }
                return try await relay?(token) ?? "grant-\(token.map { String(format: "%02x", $0) }.joined())"
            }
            $0.secrets.load = { id in DaemonSecrets(token: "token-\(id)") }
            $0.daemonClient.setPush = { connection, deviceID, registration in
                #expect(connection.endpoint.token == "token-\(connection.daemonID)")
                recorder.puts.withValue { $0.append(deviceID) }
                recorder.registrations.withValue { $0.append(registration) }
                try await daemon?(deviceID)
            }
            $0.daemonClient.deletePush = { _, deviceID in
                recorder.deletes.withValue { $0.append(deviceID) }
                try await daemon?(deviceID)
            }
        }
    }

    // MARK: Permission

    @Test func launchWithPairedDaemonsAsksOnceThenRegistersForPushes() async {
        let recorder = PushRecorder()
        let store = Self.store(authorization: .notDetermined, recorder: recorder)

        await store.send(.daemonsLoaded([.dionysus])) {
            $0.daemons = [.dionysus]
            $0.hasLoadedDaemons = true
        }
        await store.receive(\.authorizationChanged, .authorized) { $0.authorization = .authorized }

        #expect(recorder.prompts.value == 1)
        #expect(recorder.apnsRequests.value == 1)
    }

    @Test func launchWithNothingPairedDoesNotAsk() async {
        let recorder = PushRecorder()
        let store = Self.store(authorization: .notDetermined, recorder: recorder)

        await store.send(.daemonsLoaded([])) { $0.hasLoadedDaemons = true }
        await store.receive(\.authorizationChanged, .notDetermined) { $0.authorization = .notDetermined }

        #expect(recorder.prompts.value == 0)
        #expect(recorder.apnsRequests.value == 0)
    }

    @Test func theFirstPairingAsks() async {
        let recorder = PushRecorder()
        let store = Self.store(authorization: .notDetermined, recorder: recorder)

        await store.send(.daemonPaired(.dionysus)) { $0.daemons = [.dionysus] }
        await store.receive(\.authorizationChanged, .authorized) { $0.authorization = .authorized }

        #expect(recorder.prompts.value == 1)
        #expect(recorder.apnsRequests.value == 1)
    }

    @Test func aRefusalIsRememberedAndNothingRegisters() async {
        let recorder = PushRecorder()
        let store = Self.store(authorization: .notDetermined, grant: false, recorder: recorder)

        await store.send(.daemonPaired(.dionysus)) { $0.daemons = [.dionysus] }
        await store.receive(\.authorizationChanged, .denied) { $0.authorization = .denied }

        #expect(recorder.apnsRequests.value == 0)
    }

    // MARK: Registration

    @Test func aTokenRegistersWithTheRelayThenEveryDaemon() async {
        let recorder = PushRecorder()
        let store = Self.store(PushNotifications.State(daemons: [.dionysus, .hestia]), recorder: recorder)

        await store.send(.tokenReceived(Self.tokenA)) { $0.apnsToken = Self.tokenA }
        await store.receive(\.relayResponded) { $0.grant = "grant-aa01" }
        await store.receive(\.daemonUpdated)
        await store.receive(\.daemonUpdated)

        #expect(recorder.relay.value == [Self.tokenA])
        #expect(Set(recorder.puts.value) == ["dev-1", "dev-2"])
        let expected = LeoPushRegistration(grant: "grant-aa01", key: LeoPushKey.fixture.base64, relayURL: Self.relayURL)
        #expect(recorder.registrations.value == [expected, expected])
    }

    @Test func aNewTokenRegistersAgain() async {
        let recorder = PushRecorder()
        let store = Self.store(PushNotifications.State(daemons: [.dionysus]), recorder: recorder)

        await store.send(.tokenReceived(Self.tokenA)) { $0.apnsToken = Self.tokenA }
        await store.receive(\.relayResponded) { $0.grant = "grant-aa01" }
        await store.receive(\.daemonUpdated)
        await store.send(.tokenReceived(Self.tokenB)) { $0.apnsToken = Self.tokenB }
        await store.receive(\.relayResponded) { $0.grant = "grant-bb02" }
        await store.receive(\.daemonUpdated)

        #expect(recorder.relay.value == [Self.tokenA, Self.tokenB])
        #expect(recorder.registrations.value.map(\.grant) == ["grant-aa01", "grant-bb02"])
    }

    @Test func aGrantForAReplacedTokenIsDropped() async {
        let recorder = PushRecorder()
        var state = PushNotifications.State(daemons: [.dionysus])
        state.apnsToken = Self.tokenB
        let store = Self.store(state, recorder: recorder)

        await store.send(.relayResponded(token: Self.tokenA, .success("stale")))
        #expect(recorder.puts.value.isEmpty)
    }

    @Test func aNewPairingRegistersThatDaemonWithTheCurrentGrant() async {
        let recorder = PushRecorder()
        var state = PushNotifications.State(daemons: [.dionysus])
        state.apnsToken = Self.tokenA
        state.grant = "grant-aa01"
        state.authorization = .authorized
        let store = Self.store(state, recorder: recorder)
        // The permission check and the registration run side by side.
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.daemonPaired(.hestia)) { $0.daemons = [.dionysus, .hestia] }
        await store.finish()

        #expect(recorder.puts.value == ["dev-2"])
        #expect(recorder.registrations.value.map(\.grant) == ["grant-aa01"])
        #expect(recorder.prompts.value == 0)
    }

    // MARK: Errors

    @Test func aRelayFailureIsShownAndDoesNotRegister() async {
        let recorder = PushRecorder()
        let store = Self.store(
            PushNotifications.State(daemons: [.dionysus]), recorder: recorder,
            relay: { _ in throw LeoPushRelayError.status(429) }
        )

        await store.send(.tokenReceived(Self.tokenA)) { $0.apnsToken = Self.tokenA }
        await store.receive(\.relayResponded) {
            $0.relayError = "Couldn't register with the push relay (HTTP 429)."
        }
        #expect(recorder.puts.value.isEmpty)
    }

    @Test func aDaemonFailureIsShownPerDaemonAndClearsOnSuccess() async {
        let recorder = PushRecorder()
        let failing = LockIsolated(true)
        let store = Self.store(
            PushNotifications.State(daemons: [.dionysus, .hestia]), recorder: recorder,
            daemon: { deviceID in
                if deviceID == "dev-1", failing.value {
                    throw LeoDaemonError.daemon(code: "not_found", message: "HTTP 404", matches: [])
                }
            }
        )
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.tokenReceived(Self.tokenA))
        await store.receive(\.relayResponded)
        await store.receive(\.daemonUpdated)
        await store.receive(\.daemonUpdated)
        #expect(store.state.daemonErrors == ["d-dionysus": "HTTP 404"])

        failing.setValue(false)
        await store.send(.tokenReceived(Self.tokenB))
        await store.receive(\.relayResponded)
        await store.receive(\.daemonUpdated)
        await store.receive(\.daemonUpdated)
        #expect(store.state.daemonErrors.isEmpty)
    }

    @Test func aBuildWithoutARelayExplainsAndCallsNothing() async {
        let recorder = PushRecorder()
        let store = Self.store(PushNotifications.State(daemons: [.dionysus]), recorder: recorder)
        store.dependencies.pushConfiguration = PushConfiguration(relayURL: nil, environment: .sandbox)

        await store.send(.tokenReceived(Self.tokenA)) {
            $0.apnsToken = Self.tokenA
            $0.relayError = "This build has no push relay configured."
        }
        #expect(recorder.relay.value.isEmpty)
    }

    // MARK: Settings toggle

    @Test func turningNotificationsOffUnregistersEverywhereAndIgnoresNewTokens() async {
        let recorder = PushRecorder()
        var state = PushNotifications.State(daemons: [.dionysus, .hestia])
        state.apnsToken = Self.tokenA
        state.grant = "grant-aa01"
        state.daemonErrors = ["d-hestia": "HTTP 500"]
        let store = Self.store(state, recorder: recorder)
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggled(false)) {
            $0.$isEnabled.withLock { $0 = false }
            $0.$pendingUnregister.withLock { $0 = ["d-dionysus", "d-hestia"] }
            $0.daemonErrors = [:]
        }
        await store.receive(\.unregistered)
        await store.receive(\.unregistered)
        #expect(Set(recorder.deletes.value) == ["dev-1", "dev-2"])
        #expect(store.state.pendingUnregister.isEmpty)

        await store.send(.tokenReceived(Self.tokenB))
        await store.send(.daemonPaired(.dionysus))
        await store.finish()
        #expect(recorder.relay.value.isEmpty)
        #expect(recorder.puts.value.isEmpty)
        #expect(recorder.apnsRequests.value == 0)
    }

    @Test func turningNotificationsOffStopsAPNsDeliveryEvenWhenTheDaemonIsUnreachable() async {
        let recorder = PushRecorder()
        let store = Self.store(
            PushNotifications.State(daemons: [.dionysus]), recorder: recorder,
            daemon: { _ in throw LeoDaemonError.transport("offline") }
        )
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.toggled(false))
        await store.finish()

        #expect(recorder.apnsUnregistrations.value == 1)
        #expect(store.state.pendingUnregister == ["d-dionysus"])
    }

    @Test func aFailedTurnOffStaysPendingIsShownAndRetriesOnForeground() async {
        let recorder = PushRecorder()
        let offline = LockIsolated(true)
        let store = Self.store(
            PushNotifications.State(daemons: [.dionysus]), recorder: recorder,
            daemon: { _ in if offline.value { throw LeoDaemonError.transport("offline") } }
        )

        await store.send(.toggled(false)) {
            $0.$isEnabled.withLock { $0 = false }
            $0.$pendingUnregister.withLock { $0 = ["d-dionysus"] }
        }
        await store.receive(\.unregistered) { $0.daemonErrors = ["d-dionysus": "offline"] }
        #expect(store.state.problems == [PushProblem(id: "d-dionysus", message: "dionysus: offline")])

        offline.setValue(false)
        // Shared state changes from the retry land before its action is
        // asserted, so check the outcome rather than each step.
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.becameActive)
        await store.receive(\.authorizationRefreshed)
        await store.receive(\.unregistered)
        #expect(store.state.pendingUnregister.isEmpty)
        #expect(store.state.daemonErrors.isEmpty)
        #expect(store.state.authorization == .authorized)
        #expect(recorder.deletes.value == ["dev-1", "dev-1"])
    }

    @Test func aLaunchWithNotificationsOffFinishesAPendingTurnOff() async {
        let recorder = PushRecorder()
        let state = PushNotifications.State()
        state.$isEnabled.withLock { $0 = false }
        state.$pendingUnregister.withLock { $0 = ["d-dionysus", "d-gone"] }
        let store = Self.store(state, recorder: recorder)

        await store.send(.daemonsLoaded([.dionysus])) {
            $0.daemons = [.dionysus]
            $0.hasLoadedDaemons = true
            // A daemon no longer paired has nothing left to unregister here.
            $0.$pendingUnregister.withLock { $0 = ["d-dionysus"] }
        }
        await store.receive(\.unregistered) { $0.$pendingUnregister.withLock { $0 = [] } }
        #expect(recorder.deletes.value == ["dev-1"])
    }

    /// A cold launch can come to the foreground before the pairings load:
    /// an empty list then means "not read yet", not "nothing paired".
    @Test func aForegroundBeforeThePairingsLoadKeepsPendingTurnOffs() async {
        let recorder = PushRecorder()
        let state = PushNotifications.State()
        state.$isEnabled.withLock { $0 = false }
        state.$pendingUnregister.withLock { $0 = ["d-dionysus"] }
        let store = Self.store(state, recorder: recorder)

        await store.send(.becameActive)
        await store.receive(\.authorizationRefreshed) { $0.authorization = .authorized }
        await store.send(.daemonReconnected("d-dionysus"))
        await store.send(.toggled(false))
        #expect(store.state.pendingUnregister == ["d-dionysus"])
        #expect(recorder.deletes.value.isEmpty)

        await store.send(.daemonsLoaded([.dionysus])) {
            $0.daemons = [.dionysus]
            $0.hasLoadedDaemons = true
        }
        await store.receive(\.unregistered) { $0.$pendingUnregister.withLock { $0 = [] } }
        #expect(recorder.deletes.value == ["dev-1"])
    }

    @Test func aReconnectFinishesThatDaemonsPendingTurnOff() async {
        let recorder = PushRecorder()
        let state = PushNotifications.State(daemons: [.dionysus, .hestia])
        state.$isEnabled.withLock { $0 = false }
        state.$pendingUnregister.withLock { $0 = ["d-dionysus", "d-hestia"] }
        let store = Self.store(state, recorder: recorder)

        await store.send(.daemonReconnected("d-hestia"))
        await store.receive(\.unregistered) { $0.$pendingUnregister.withLock { $0 = ["d-dionysus"] } }
        #expect(recorder.deletes.value == ["dev-2"])
    }

    @Test func aRevokedDeviceHasNothingLeftToUnregister() async {
        let recorder = PushRecorder()
        let state = PushNotifications.State(daemons: [.dionysus])
        state.$isEnabled.withLock { $0 = false }
        state.$pendingUnregister.withLock { $0 = ["d-dionysus"] }
        let store = Self.store(state, recorder: recorder, daemon: { _ in
            throw LeoDaemonError.daemon(code: "unauthorized", message: "HTTP 401", matches: [])
        })

        await store.send(.daemonReconnected("d-dionysus"))
        await store.receive(\.unregistered) { $0.$pendingUnregister.withLock { $0 = [] } }
    }

    @Test func turningNotificationsOnDropsAPendingTurnOff() async {
        let recorder = PushRecorder()
        let state = PushNotifications.State(daemons: [.dionysus])
        state.$isEnabled.withLock { $0 = false }
        state.$pendingUnregister.withLock { $0 = ["d-dionysus"] }
        let store = Self.store(state, recorder: recorder)

        await store.send(.toggled(true)) {
            $0.$isEnabled.withLock { $0 = true }
            $0.$pendingUnregister.withLock { $0 = [] }
        }
        await store.receive(\.authorizationChanged) { $0.authorization = .authorized }
        await store.send(.daemonReconnected("d-dionysus"))
        #expect(recorder.deletes.value.isEmpty)
    }

    @Test func turningNotificationsBackOnAsksForAToken() async {
        let recorder = PushRecorder()
        let state = PushNotifications.State(daemons: [.dionysus])
        state.$isEnabled.withLock { $0 = false }
        let store = Self.store(state, recorder: recorder)

        await store.send(.toggled(true)) { $0.$isEnabled.withLock { $0 = true } }
        await store.receive(\.authorizationChanged, .authorized) { $0.authorization = .authorized }
        #expect(recorder.apnsRequests.value == 1)

        // The token that answers goes through the relay to the daemon.
        await store.send(.tokenReceived(Self.tokenA)) { $0.apnsToken = Self.tokenA }
        await store.receive(\.relayResponded) { $0.grant = "grant-aa01" }
        await store.receive(\.daemonUpdated)
        #expect(recorder.puts.value == ["dev-1"])
    }

    // MARK: Forgetting

    @Test func forgettingKeepsACleanupRecordUntilTheDaemonUnregisters() async {
        let recorder = PushRecorder()
        let store = Self.store(PushNotifications.State(daemons: [.dionysus, .hestia]), recorder: recorder)

        await store.send(.daemonForgotten(.dionysus)) { $0.daemons = [.hestia] }
        await store.receive(\.cleanupRecorded)
        await store.finish()
        #expect(recorder.deletes.value == ["dev-1"])
        #expect(recorder.cleanup.value.isEmpty)
        #expect(recorder.shared.value.last == ["d-hestia"])
    }

    @Test func forgettingAnOfflineDaemonRetriesItsCleanupOnForeground() async {
        let recorder = PushRecorder()
        let offline = LockIsolated(true)
        let store = Self.store(
            PushNotifications.State(daemons: [.dionysus]), recorder: recorder,
            daemon: { _ in if offline.value { throw LeoDaemonError.transport("offline") } }
        )

        await store.send(.daemonForgotten(.dionysus)) { $0.daemons = [] }
        await store.receive(\.cleanupRecorded)
        await store.finish()
        // The token outlives the pairing, under the cleanup record.
        #expect(recorder.cleanup.value == ["dev-1": ForgottenDaemon(daemon: .dionysus, secrets: DaemonSecrets(token: "token-d-dionysus"))])

        offline.setValue(false)
        await store.send(.becameActive)
        await store.receive(\.authorizationRefreshed) { $0.authorization = .authorized }
        await store.finish()
        #expect(recorder.deletes.value == ["dev-1", "dev-1"])
        #expect(recorder.cleanup.value.isEmpty)
    }

    @Test func aRevokedForgottenDeviceDropsItsCleanupRecord() async {
        let recorder = PushRecorder()
        let store = Self.store(PushNotifications.State(daemons: [.dionysus]), recorder: recorder, daemon: { _ in
            throw LeoDaemonError.daemon(code: "forbidden", message: "HTTP 403", matches: [])
        })

        await store.send(.daemonForgotten(.dionysus)) { $0.daemons = [] }
        await store.receive(\.cleanupRecorded)
        await store.finish()
        #expect(recorder.cleanup.value.isEmpty)
    }

    @Test func forgettingADaemonWithoutSecretsSendsNothing() async {
        let recorder = PushRecorder()
        let store = Self.store(PushNotifications.State(daemons: [.dionysus]), recorder: recorder)
        store.dependencies.secrets.load = { _ in nil }

        await store.send(.daemonForgotten(.dionysus)) { $0.daemons = [] }
        await store.finish()
        #expect(recorder.deletes.value.isEmpty)
        #expect(recorder.cleanup.value.isEmpty)
    }

    // MARK: Foreground

    @Test func allowingNotificationsInSystemSettingsRegistersOnForeground() async {
        let recorder = PushRecorder()
        var state = PushNotifications.State(daemons: [.dionysus])
        state.authorization = .denied
        state.apnsToken = Self.tokenA
        state.grant = "grant-aa01"
        let store = Self.store(state, recorder: recorder)

        await store.send(.becameActive)
        await store.receive(\.authorizationRefreshed, .authorized) { $0.authorization = .authorized }
        await store.finish()
        #expect(recorder.apnsRequests.value == 1)

        // Already allowed: coming back again asks for nothing.
        await store.send(.becameActive)
        await store.receive(\.authorizationRefreshed, .authorized)
        await store.finish()
        #expect(recorder.apnsRequests.value == 1)
    }

    @Test func aForegroundRetriesATokenRequestThatNeverReachedTheRelay() async {
        let recorder = PushRecorder()
        var state = PushNotifications.State(daemons: [.dionysus])
        state.authorization = .authorized
        state.relayError = "Couldn't register with the push relay (HTTP 503)."
        let store = Self.store(state, recorder: recorder)

        await store.send(.becameActive)
        await store.receive(\.authorizationRefreshed, .authorized)
        await store.finish()
        #expect(recorder.apnsRequests.value == 1)
    }

    @Test func aForegroundRetriesATokenThatNeverArrived() async {
        let recorder = PushRecorder()
        var state = PushNotifications.State(daemons: [.dionysus])
        state.authorization = .authorized
        state.relayError = "This device couldn't get a push token (no network)."
        let store = Self.store(state, recorder: recorder)

        await store.send(.becameActive)
        await store.receive(\.authorizationRefreshed, .authorized)
        await store.finish()
        #expect(recorder.apnsRequests.value == 1)
    }

    @Test func aForegroundRetriesADaemonThatFailedToRegister() async {
        let recorder = PushRecorder()
        var state = PushNotifications.State(daemons: [.dionysus, .hestia])
        state.authorization = .authorized
        state.apnsToken = Self.tokenA
        state.grant = "grant-aa01"
        state.daemonErrors = ["d-hestia": "offline"]
        let store = Self.store(state, recorder: recorder)
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.becameActive)
        await store.receive(\.daemonUpdated)
        await store.finish()
        #expect(recorder.puts.value == ["dev-2"])
        #expect(store.state.daemonErrors.isEmpty)
    }

    @Test func aReconnectRetriesThatDaemonsFailedRegistration() async {
        let recorder = PushRecorder()
        var state = PushNotifications.State(daemons: [.dionysus, .hestia])
        state.authorization = .authorized
        state.apnsToken = Self.tokenA
        state.grant = "grant-aa01"
        state.daemonErrors = ["d-dionysus": "offline", "d-hestia": "offline"]
        let store = Self.store(state, recorder: recorder)

        await store.send(.daemonReconnected("d-hestia"))
        await store.receive(\.daemonUpdated) { $0.daemonErrors = ["d-dionysus": "offline"] }
        #expect(recorder.puts.value == ["dev-2"])
    }

    @Test func aHealthyForegroundRegistersNothingAgain() async {
        let recorder = PushRecorder()
        var state = PushNotifications.State(daemons: [.dionysus])
        state.authorization = .authorized
        state.apnsToken = Self.tokenA
        state.grant = "grant-aa01"
        let store = Self.store(state, recorder: recorder)

        await store.send(.becameActive)
        await store.receive(\.authorizationRefreshed, .authorized)
        await store.finish()
        #expect(recorder.apnsRequests.value == 0)
        #expect(recorder.puts.value.isEmpty)
    }

    @Test func aForegroundBeforeTheFirstCheckLeavesRegistrationToLaunch() async {
        let recorder = PushRecorder()
        let store = Self.store(PushNotifications.State(daemons: [.dionysus]), recorder: recorder)

        await store.send(.becameActive)
        await store.receive(\.authorizationRefreshed, .authorized) { $0.authorization = .authorized }
        await store.finish()
        #expect(recorder.apnsRequests.value == 0)
    }

    @Test func aForegroundWithNotificationsOffRegistersNothing() async {
        let recorder = PushRecorder()
        var state = PushNotifications.State(daemons: [.dionysus])
        state.$isEnabled.withLock { $0 = false }
        state.authorization = .denied
        let store = Self.store(state, recorder: recorder)

        await store.send(.becameActive)
        await store.receive(\.authorizationRefreshed, .authorized) { $0.authorization = .authorized }
        await store.finish()
        #expect(recorder.apnsRequests.value == 0)
    }

    // MARK: Sharing with the extension

    @Test func theExtensionLearnsWhichDaemonsArePaired() async {
        let recorder = PushRecorder()
        let store = Self.store(authorization: .denied, recorder: recorder)
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.daemonsLoaded([.dionysus]))
        await store.send(.daemonPaired(.hestia))
        await store.finish()
        #expect(recorder.shared.value == [["d-dionysus"], ["d-dionysus", "d-hestia"]])
    }

    // MARK: Settings problems

    @Test func problemsAreIdentifiedByDaemonNotByText() {
        var twin = PairedDaemon.hestia
        twin.name = PairedDaemon.dionysus.name
        var state = PushNotifications.State(daemons: [.dionysus, twin])
        state.relayError = "relay down"
        state.daemonErrors = ["d-dionysus": "HTTP 500", "d-hestia": "HTTP 500"]

        #expect(state.problems.map(\.id) == ["relay", "d-dionysus", "d-hestia"])
        #expect(state.problems.map(\.message) == ["relay down", "dionysus: HTTP 500", "dionysus: HTTP 500"])

        // Off, only the clean-up failures matter.
        state.$isEnabled.withLock { $0 = false }
        #expect(state.problems.map(\.id) == ["d-dionysus", "d-hestia"])
    }
}

struct PushConfigurationTests {
    @Test func readsTheRelayAndEnvironmentFromInfoPlist() {
        let configuration = PushConfiguration(infoDictionary: [
            "LeoPushRelayURL": "https://leo-relay.blackpaw.workers.dev", "LeoAPNsEnvironment": "sandbox",
        ])
        #expect(configuration == PushConfiguration(relayURL: URL(string: "https://leo-relay.blackpaw.workers.dev"), environment: .sandbox))
    }

    @Test(arguments: ["https://leo-relay.<placeholder>.workers.dev", "http://leo-relay.blackpaw.workers.dev", "", "localhost", "https://localhost"])
    func anUnfilledOrInsecureRelayIsNoRelay(raw: String) {
        #expect(PushConfiguration(infoDictionary: ["LeoPushRelayURL": raw]).relayURL == nil)
    }

    @Test func anUnknownEnvironmentMeansProduction() {
        #expect(PushConfiguration(infoDictionary: ["LeoAPNsEnvironment": "$(LEO_APNS_ENVIRONMENT)"]).environment == .production)
    }
}
