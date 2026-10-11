import ComposableArchitecture
import Foundation
import LeoKit

/// Push registration. The APNs token goes to the relay for a grant; the
/// grant, the phone's push key and the relay URL go to every paired daemon.
/// Runs on launch, on each token, on each new pairing and when the Settings
/// switch turns on; the switch turning off unregisters everywhere.
@Reducer
public struct PushNotifications {
    @ObservableState
    public struct State: Equatable {
        @Shared(.notificationsEnabled) public var isEnabled
        /// Nil until checked.
        public var authorization: PushAuthorization?
        /// Every paired daemon, kept in step by the parent.
        public var daemons: IdentifiedArrayOf<PairedDaemon>
        public var apnsToken: Data?
        /// The relay's grant for `apnsToken`.
        public var grant: String?
        public var relayError: String?
        /// Why registering with (or unregistering from) a daemon last failed.
        public var daemonErrors: [PairedDaemon.ID: String] = [:]

        public init(daemons: IdentifiedArrayOf<PairedDaemon> = []) {
            self.daemons = daemons
        }
    }

    public enum Action {
        case authorizationChanged(PushAuthorization)
        case daemonForgotten(PairedDaemon)
        case daemonPaired(PairedDaemon)
        case daemonsLoaded([PairedDaemon])
        case daemonUpdated(PairedDaemon.ID, Result<Void, any Error>)
        case relayResponded(token: Data, Result<String, any Error>)
        case remoteNotificationsFailed(String)
        case toggled(Bool)
        case tokenReceived(Data)
        /// A forgotten daemon's connection, read before its token is deleted.
        case unregister(DaemonConnection, deviceID: String)
    }

    enum CancelID: Hashable {
        case daemon(PairedDaemon.ID)
        case relay
    }

    @Dependency(\.daemonClient) var daemonClient
    @Dependency(\.pushClient) var pushClient
    @Dependency(\.pushConfiguration) var configuration
    @Dependency(\.pushRelay) var relay
    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .authorizationChanged(let authorization):
                state.authorization = authorization
                return .none

            case .daemonForgotten(let daemon):
                state.daemons.remove(id: daemon.id)
                state.daemonErrors[daemon.id] = nil
                let secrets = secrets
                // Only reads the token: the DELETE runs as its own effect, so
                // the parent can delete the token straight after this one.
                return .run { send in
                    guard let saved = try? secrets.load(daemon.id) else { return }
                    await send(.unregister(DaemonConnection(daemon: daemon, secrets: saved), deviceID: daemon.deviceID))
                }

            case .daemonPaired(let daemon):
                state.daemons[id: daemon.id] = daemon
                guard state.isEnabled else { return .none }
                // After a first pairing is when asking makes sense.
                return .merge(authorize(prompting: true), register(daemon, state: state))

            case .daemonsLoaded(let daemons):
                state.daemons = IdentifiedArray(daemons, uniquingIDsWith: { $1 })
                guard state.isEnabled else { return .none }
                return authorize(prompting: !daemons.isEmpty)

            case .daemonUpdated(let id, .success):
                state.daemonErrors[id] = nil
                return .none

            case .daemonUpdated(let id, .failure(let error)):
                guard state.daemons[id: id] != nil else { return .none }
                state.daemonErrors[id] = Self.message(for: error)
                return .none

            case .relayResponded(let token, .success(let grant)):
                guard token == state.apnsToken else { return .none }
                state.grant = grant
                state.relayError = nil
                guard state.isEnabled else { return .none }
                return .merge(state.daemons.map { register($0, state: state) })

            case .relayResponded(let token, .failure(let error)):
                guard token == state.apnsToken else { return .none }
                state.relayError = "Couldn't register with the push relay (\(Self.message(for: error)))."
                return .none

            case .remoteNotificationsFailed(let reason):
                state.relayError = "This device couldn't get a push token (\(reason))."
                return .none

            case .toggled(true):
                state.$isEnabled.withLock { $0 = true }
                // The token that answers re-registers everywhere.
                return authorize(prompting: true)

            case .toggled(false):
                state.$isEnabled.withLock { $0 = false }
                state.daemonErrors = [:]
                return .merge([.cancel(id: CancelID.relay)] + state.daemons.map(unregister))

            case .tokenReceived(let token):
                state.apnsToken = token
                guard state.isEnabled else { return .none }
                guard let relayURL = configuration.relayURL else {
                    state.relayError = "This build has no push relay configured."
                    return .none
                }
                let (relay, environment) = (relay, configuration.environment)
                return .run { send in
                    await send(.relayResponded(token: token, Result { try await relay.register(relayURL, token, environment) }))
                }
                .cancellable(id: CancelID.relay, cancelInFlight: true)

            case .unregister(let connection, let deviceID):
                let daemonClient = daemonClient
                return .run { send in
                    await send(.daemonUpdated(connection.daemonID, Result { try await daemonClient.deletePush(connection, deviceID) }))
                }
                .cancellable(id: CancelID.daemon(connection.daemonID), cancelInFlight: true)
            }
        }
    }

    /// Checks permission, asking first when `prompting` and the user hasn't
    /// been asked; once allowed, requests a token.
    private func authorize(prompting: Bool) -> Effect<Action> {
        let pushClient = pushClient
        return .run { send in
            var authorization = await pushClient.authorization()
            if authorization == .notDetermined, prompting {
                authorization = (try? await pushClient.requestAuthorization()) == true ? .authorized : .denied
            }
            await send(.authorizationChanged(authorization))
            if authorization == .authorized { await pushClient.registerForRemoteNotifications() }
        }
    }

    /// Hands the daemon the current grant, the push key and the relay URL.
    /// Nothing to send until the relay has answered.
    private func register(_ daemon: PairedDaemon, state: State) -> Effect<Action> {
        guard let grant = state.grant, let relayURL = configuration.relayURL else { return .none }
        let (daemonClient, pushClient, secrets) = (daemonClient, pushClient, secrets)
        return .run { send in
            await send(.daemonUpdated(daemon.id, Result {
                guard let saved = try secrets.load(daemon.id) else { throw PushRegistrationError.noToken }
                let registration = LeoPushRegistration(grant: grant, key: try pushClient.key().base64, relayURL: relayURL)
                try await daemonClient.setPush(DaemonConnection(daemon: daemon, secrets: saved), daemon.deviceID, registration)
            }))
        }
        .cancellable(id: CancelID.daemon(daemon.id), cancelInFlight: true)
    }

    private func unregister(_ daemon: PairedDaemon) -> Effect<Action> {
        let (daemonClient, secrets) = (daemonClient, secrets)
        return .run { send in
            await send(.daemonUpdated(daemon.id, Result {
                guard let saved = try secrets.load(daemon.id) else { throw PushRegistrationError.noToken }
                try await daemonClient.deletePush(DaemonConnection(daemon: daemon, secrets: saved), daemon.deviceID)
            }))
        }
        .cancellable(id: CancelID.daemon(daemon.id), cancelInFlight: true)
    }

    static func message(for error: any Error) -> String {
        switch error {
        case LeoPushRelayError.status(let status): "HTTP \(status)"
        case LeoPushRelayError.malformedResponse: "unexpected response"
        case LeoDaemonError.daemon(_, let message, _): message
        case LeoDaemonError.transport(let reason): reason
        case LeoDaemonError.timeout: "timed out"
        default: error.localizedDescription
        }
    }
}

enum PushRegistrationError: Error, LocalizedError {
    case noToken

    var errorDescription: String? { "No saved token for this daemon. Pair it again." }
}
