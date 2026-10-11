import ComposableArchitecture
import Foundation
import LeoKit

/// Pairs this device with a daemon from a `leo pair` payload, scanned as a
/// QR code or pasted. The token goes straight to the Keychain.
@Reducer
public struct Pairing {
    @ObservableState
    public struct State: Equatable {
        public var payloadText: String
        public var cfClientID: String
        public var cfClientSecret: String
        public var isPairing: Bool
        public var isScannerPresented: Bool
        public var errorMessage: String?

        public init(
            payloadText: String = "", cfClientID: String = "", cfClientSecret: String = "",
            isPairing: Bool = false, isScannerPresented: Bool = false, errorMessage: String? = nil
        ) {
            self.payloadText = payloadText
            self.cfClientID = cfClientID
            self.cfClientSecret = cfClientSecret
            self.isPairing = isPairing
            self.isScannerPresented = isScannerPresented
            self.errorMessage = errorMessage
        }

        public var canPair: Bool {
            !isPairing && !payloadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case cancelButtonTapped
        case codeScanned(String)
        case delegate(Delegate)
        case pairButtonTapped
        case pairResponse(Result<PairedDaemon, any Error>)
        case scanButtonTapped
        case scannerDismissed

        @CasePathable
        public enum Delegate {
            case cancel
            case paired(PairedDaemon)
        }
    }

    @Dependency(\.daemonClient) var daemonClient
    @Dependency(\.deviceName) var deviceName
    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                state.errorMessage = nil
                return .none

            case .cancelButtonTapped:
                return .send(.delegate(.cancel))

            case .codeScanned(let text):
                state.isScannerPresented = false
                state.payloadText = text
                return pair(state: &state)

            case .delegate:
                return .none

            case .pairButtonTapped:
                return pair(state: &state)

            case .pairResponse(.success(let daemon)):
                state.isPairing = false
                return .send(.delegate(.paired(daemon)))

            case .pairResponse(.failure(let error)):
                state.isPairing = false
                state.errorMessage = Self.message(for: error)
                return .none

            case .scanButtonTapped:
                state.errorMessage = nil
                state.isScannerPresented = true
                return .none

            case .scannerDismissed:
                state.isScannerPresented = false
                return .none
            }
        }
    }

    private func pair(state: inout State) -> Effect<Action> {
        guard !state.isPairing else { return .none }
        let payload: LeoPairingPayload
        do {
            payload = try LeoPairingPayload.parse(state.payloadText)
        } catch {
            state.errorMessage = error.localizedDescription
            return .none
        }
        let clientID = state.cfClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = state.cfClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientID.isEmpty == clientSecret.isEmpty else {
            state.errorMessage = "Enter both the Cloudflare Access client ID and secret, or neither."
            return .none
        }
        let cfAccess = clientID.isEmpty ? nil : LeoCFAccessCredentials(clientID: clientID, clientSecret: clientSecret)
        state.errorMessage = nil
        state.isPairing = true
        let (daemonClient, secrets, deviceName) = (daemonClient, secrets, deviceName)
        return .run { send in
            await send(.pairResponse(Result {
                let (baseURL, grant) = try await Self.redeem(payload, cfAccess: cfAccess, deviceName: deviceName, client: daemonClient)
                try secrets.save(DaemonSecrets(token: grant.token, cfAccess: cfAccess), payload.daemonID)
                @Dependency(\.date.now) var now
                return PairedDaemon(
                    id: payload.daemonID, name: payload.name, baseURL: baseURL, urls: payload.urls,
                    deviceID: grant.deviceID, pairedAt: now
                )
            }))
        }
    }

    /// Tries each advertised origin in order. Only an unreachable origin
    /// moves on: any answer from the daemon (even a refusal) is final, since
    /// the code is spent on first use.
    private static func redeem(
        _ payload: LeoPairingPayload, cfAccess: LeoCFAccessCredentials?, deviceName: String, client: DaemonClient
    ) async throws -> (URL, LeoPairingGrant) {
        var lastReason = ""
        for url in payload.urls {
            do {
                return (url, try await client.pair(url, payload.pairingCode, deviceName, cfAccess))
            } catch LeoDaemonError.transport(let reason) {
                lastReason = reason
            } catch LeoDaemonError.timeout {
                lastReason = "The request timed out."
            }
        }
        throw PairingUnreachable(name: payload.name, urls: payload.urls, reason: lastReason)
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let unreachable as PairingUnreachable:
            let hosts = unreachable.urls.map { url in url.port.map { "\(url.host() ?? ""):\($0)" } ?? url.host() ?? url.absoluteString }
            return "Couldn't reach \(unreachable.name) at \(Self.orList(hosts)). Check that this device can reach the daemon. (\(unreachable.reason))"
        case LeoDaemonError.daemon(let code, let message, _):
            switch code {
            case "unauthorized": return "This pairing code is invalid, expired or already used. Run `leo pair` again for a new one."
            case "rate_limited": return "Too many pairing attempts. Wait a minute, then try again."
            case "unavailable": return "Pairing isn't available on this daemon. Update leo and try again."
            case "forbidden": return "The daemon refused the request (\(message)). If it's behind Cloudflare Access, add a service token."
            default: return message
            }
        default:
            return error.localizedDescription
        }
    }
}

extension Pairing {
    /// "a", "a or b", "a, b or c".
    static func orList(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " or " + last
    }
}

struct PairingUnreachable: Error {
    let name: String
    let urls: [URL]
    let reason: String
}
