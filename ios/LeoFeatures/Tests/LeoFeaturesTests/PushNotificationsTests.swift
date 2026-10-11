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
            $0.pushClient.key = { .fixture }
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

        await store.send(.daemonsLoaded([.dionysus])) { $0.daemons = [.dionysus] }
        await store.receive(\.authorizationChanged, .authorized) { $0.authorization = .authorized }

        #expect(recorder.prompts.value == 1)
        #expect(recorder.apnsRequests.value == 1)
    }

    @Test func launchWithNothingPairedDoesNotAsk() async {
        let recorder = PushRecorder()
        let store = Self.store(authorization: .notDetermined, recorder: recorder)

        await store.send(.daemonsLoaded([]))
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

        await store.send(.toggled(false)) {
            $0.$isEnabled.withLock { $0 = false }
            $0.daemonErrors = [:]
        }
        await store.receive(\.daemonUpdated)
        await store.receive(\.daemonUpdated)
        #expect(Set(recorder.deletes.value) == ["dev-1", "dev-2"])

        await store.send(.tokenReceived(Self.tokenB)) { $0.apnsToken = Self.tokenB }
        await store.send(.daemonPaired(.dionysus))
        #expect(recorder.relay.value.isEmpty)
        #expect(recorder.puts.value.isEmpty)
        #expect(recorder.apnsRequests.value == 0)
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

    @Test func forgettingADaemonUnregistersIt() async {
        let recorder = PushRecorder()
        var state = PushNotifications.State(daemons: [.dionysus, .hestia])
        state.grant = "grant-aa01"
        let store = Self.store(state, recorder: recorder)

        await store.send(.daemonForgotten(.dionysus)) { $0.daemons = [.hestia] }
        await store.receive(\.unregister)
        await store.receive(\.daemonUpdated)
        #expect(recorder.deletes.value == ["dev-1"])
    }

    @Test func forgettingADaemonWithoutSecretsSendsNothing() async {
        let recorder = PushRecorder()
        let store = Self.store(PushNotifications.State(daemons: [.dionysus]), recorder: recorder)
        store.dependencies.secrets.load = { _ in nil }

        await store.send(.daemonForgotten(.dionysus)) { $0.daemons = [] }
        #expect(recorder.deletes.value.isEmpty)
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
