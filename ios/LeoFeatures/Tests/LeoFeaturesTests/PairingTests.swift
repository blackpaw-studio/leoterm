import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct PairingTests {
    static let payload = #"{"daemon_id":"d-dionysus","name":"dionysus","urls":["https://leo.example.com","http://10.0.2.10:8370"],"pairing_code":"c0de"}"#
    static let now = Date(timeIntervalSince1970: 5_000)

    @Test func pairsAndStoresTheTokenInTheKeychain() async {
        let saved = LockIsolated<[String: DaemonSecrets]>([:])
        let requests = LockIsolated<[String]>([])
        let store = TestStore(initialState: Pairing.State(payloadText: Self.payload)) {
            Pairing()
        } withDependencies: {
            $0.date.now = Self.now
            $0.deviceName = "Evan's iPhone"
            $0.daemonClient.pair = { url, code, name, cfAccess in
                requests.withValue { $0.append("\(url.absoluteString) \(code) \(name) \(cfAccess == nil)") }
                return LeoPairingGrant(deviceID: "dev-1", token: "t0k")
            }
            $0.secrets.save = { secrets, id in saved.withValue { $0[id] = secrets } }
        }
        let daemon = PairedDaemon(
            id: "d-dionysus", name: "dionysus", baseURL: URL(string: "https://leo.example.com")!,
            urls: [URL(string: "https://leo.example.com")!, URL(string: "http://10.0.2.10:8370")!],
            deviceID: "dev-1", pairedAt: Self.now
        )

        await store.send(.pairButtonTapped) { $0.isPairing = true }
        await store.receive(\.pairResponse.success) { $0.isPairing = false }
        await store.receive(\.delegate.paired, daemon)

        #expect(requests.value == ["https://leo.example.com c0de Evan's iPhone true"])
        #expect(saved.value == ["d-dionysus": DaemonSecrets(token: "t0k")])
    }

    @Test func triesTheNextAddressWhenOneIsUnreachable() async {
        let tried = LockIsolated<[URL]>([])
        let store = TestStore(initialState: Pairing.State(payloadText: Self.payload)) {
            Pairing()
        } withDependencies: {
            $0.date.now = Self.now
            $0.daemonClient.pair = { url, _, _, _ in
                tried.withValue { $0.append(url) }
                if url.scheme == "https" { throw LeoDaemonError.transport("A server with the specified hostname could not be found.") }
                return LeoPairingGrant(deviceID: "dev-1", token: "t0k")
            }
            $0.secrets.save = { _, _ in }
        }
        await store.send(.pairButtonTapped) { $0.isPairing = true }
        await store.receive(\.pairResponse.success) { $0.isPairing = false }
        await store.receive(\.delegate.paired) 
        #expect(tried.value.map(\.absoluteString) == ["https://leo.example.com", "http://10.0.2.10:8370"])
        #expect(store.state.errorMessage == nil)
    }

    @Test func sendsCloudflareAccessCredentialsAndKeepsThemWithTheToken() async {
        let saved = LockIsolated<DaemonSecrets?>(nil)
        let access = LeoCFAccessCredentials(clientID: "id.access", clientSecret: "s3cret")
        let store = TestStore(initialState: Pairing.State(payloadText: Self.payload, cfClientID: " id.access ", cfClientSecret: "s3cret")) {
            Pairing()
        } withDependencies: {
            $0.date.now = Self.now
            $0.daemonClient.pair = { _, _, _, cfAccess in
                #expect(cfAccess == access)
                return LeoPairingGrant(deviceID: "dev-1", token: "t0k")
            }
            $0.secrets.save = { secrets, _ in saved.setValue(secrets) }
        }
        await store.send(.pairButtonTapped) { $0.isPairing = true }
        await store.receive(\.pairResponse.success) { $0.isPairing = false }
        await store.receive(\.delegate.paired)
        #expect(saved.value == DaemonSecrets(token: "t0k", cfAccess: access))
    }

    @Test func rejectsTextThatIsNotAPairingCode() async {
        let store = TestStore(initialState: Pairing.State(payloadText: "hello")) { Pairing() }
        await store.send(.pairButtonTapped) {
            $0.errorMessage = LeoPairingError.malformed.localizedDescription
        }
    }

    @Test func requiresBothHalvesOfACloudflareServiceToken() async {
        let store = TestStore(initialState: Pairing.State(payloadText: Self.payload, cfClientID: "id.access")) { Pairing() }
        await store.send(.pairButtonTapped) {
            $0.errorMessage = "Enter both the Cloudflare Access client ID and secret, or neither."
        }
    }

    @Test func explainsAnExpiredOrUsedCode() async {
        let store = TestStore(initialState: Pairing.State(payloadText: Self.payload)) {
            Pairing()
        } withDependencies: {
            $0.daemonClient.pair = { _, _, _, _ in
                throw LeoDaemonError.daemon(code: "unauthorized", message: "invalid or expired pairing code", matches: [])
            }
        }
        await store.send(.pairButtonTapped) { $0.isPairing = true }
        await store.receive(\.pairResponse.failure) {
            $0.isPairing = false
            $0.errorMessage = "This pairing code is invalid, expired or already used. Run `leo pair` again for a new one."
        }
    }

    @Test func reportsEveryAddressWhenNoneAnswers() async {
        let store = TestStore(initialState: Pairing.State(payloadText: Self.payload)) {
            Pairing()
        } withDependencies: {
            $0.daemonClient.pair = { _, _, _, _ in throw LeoDaemonError.transport("Could not connect to the server.") }
        }
        await store.send(.pairButtonTapped) { $0.isPairing = true }
        await store.receive(\.pairResponse.failure) {
            $0.isPairing = false
            $0.errorMessage = "Couldn't reach dionysus at leo.example.com or 10.0.2.10:8370. Check that this device can reach the daemon. (Could not connect to the server.)"
        }
    }

    @Test func explainsRateLimiting() async {
        let store = TestStore(initialState: Pairing.State(payloadText: Self.payload)) {
            Pairing()
        } withDependencies: {
            $0.daemonClient.pair = { _, _, _, _ in throw LeoDaemonError.daemon(code: "rate_limited", message: "too many", matches: []) }
        }
        await store.send(.pairButtonTapped) { $0.isPairing = true }
        await store.receive(\.pairResponse.failure) {
            $0.isPairing = false
            $0.errorMessage = "Too many pairing attempts. Wait a minute, then try again."
        }
    }

    @Test func aScannedCodePairsImmediately() async {
        let store = TestStore(initialState: Pairing.State(isScannerPresented: true)) {
            Pairing()
        } withDependencies: {
            $0.date.now = Self.now
            $0.daemonClient.pair = { _, _, _, _ in LeoPairingGrant(deviceID: "dev-1", token: "t0k") }
            $0.secrets.save = { _, _ in }
        }
        await store.send(.codeScanned(Self.payload)) {
            $0.isScannerPresented = false
            $0.payloadText = Self.payload
            $0.isPairing = true
        }
        await store.receive(\.pairResponse.success) { $0.isPairing = false }
        await store.receive(\.delegate.paired)
    }

    @Test func ignoresASecondTapWhilePairing() async {
        let store = TestStore(initialState: Pairing.State(payloadText: Self.payload, isPairing: true)) { Pairing() }
        await store.send(.pairButtonTapped)
    }
}
