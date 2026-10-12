import ComposableArchitecture
import Foundation
import LeoKit

/// A reason pushes may not arrive, for Settings.
public struct PushProblem: Hashable, Identifiable, Sendable {
    /// "relay", or the daemon's ID: never the text, which can repeat.
    public let id: String
    public let message: String
}

/// Push registration. The APNs token goes to the relay for a grant; the
/// grant, the phone's push key and the relay URL go to every paired daemon.
/// Runs on launch, on each token, on each new pairing and when the Settings
/// switch turns on.
///
/// Unregistering must outlast an unreachable daemon: turning the switch off
/// leaves each daemon pending until its DELETE succeeds, and forgetting a
/// daemon keeps a Keychain cleanup record until then. Both retry on launch,
/// on foreground, and (pending ones) when that daemon reconnects. A daemon
/// that refuses the device (revoked) has nothing left to unregister.
@Reducer
public struct PushNotifications {
    @ObservableState
    public struct State: Equatable {
        @Shared(.notificationsEnabled) public var isEnabled
        @Shared(.pushPendingUnregister) public var pendingUnregister
        /// Nil until checked.
        public var authorization: PushAuthorization?
        /// Every paired daemon, kept in step by the parent.
        public var daemons: IdentifiedArrayOf<PairedDaemon>
        /// Whether `daemons` has been read from disk. Until then an empty
        /// list means "not loaded", never "nothing paired".
        public var hasLoadedDaemons: Bool
        public var apnsToken: Data?
        /// The relay's grant for `apnsToken`.
        public var grant: String?
        public var relayError: String?
        /// Why registering with (or unregistering from) a daemon last failed.
        public var daemonErrors: [PairedDaemon.ID: String] = [:]

        /// `daemons` nil: the pairings haven't been loaded yet.
        public init(daemons: IdentifiedArrayOf<PairedDaemon>? = nil) {
            self.daemons = daemons ?? []
            hasLoadedDaemons = daemons != nil
        }

        /// What Settings lists. With notifications off, only daemons that
        /// haven't confirmed they stopped pushing.
        public var problems: [PushProblem] {
            let relay = isEnabled ? relayError.map { [PushProblem(id: "relay", message: $0)] } ?? [] : []
            return relay + daemons.compactMap { daemon in
                daemonErrors[daemon.id].map { PushProblem(id: daemon.id, message: "\(daemon.name): \($0)") }
            }
        }
    }

    public enum Action {
        case authorizationChanged(PushAuthorization)
        /// The permission as found on returning to the foreground.
        case authorizationRefreshed(PushAuthorization)
        case becameActive
        /// A forgotten daemon's token is safe in its cleanup record.
        case cleanupRecorded
        case daemonForgotten(PairedDaemon)
        case daemonPaired(PairedDaemon)
        case daemonReconnected(PairedDaemon.ID)
        case daemonsLoaded([PairedDaemon])
        case daemonUpdated(PairedDaemon.ID, Result<Void, any Error>)
        case relayResponded(token: Data, Result<String, any Error>)
        case remoteNotificationsFailed(String)
        case toggled(Bool)
        case tokenReceived(Data)
        case unregistered(PairedDaemon.ID, Result<Void, any Error>)
    }

    enum CancelID: Hashable {
        case daemon(PairedDaemon.ID)
        case forgottenSweep
        case relay
    }

    @Dependency(\.daemonClient) var daemonClient
    @Dependency(\.pushCleanup) var cleanup
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

            case .authorizationRefreshed(let authorization):
                let wasRefused = state.authorization == .denied || state.authorization == .notDetermined
                state.authorization = authorization
                // Allowed in iOS Settings since the last check. (Before the
                // first check, the launch flow registers.)
                guard state.isEnabled, wasRefused, authorization == .authorized else { return .none }
                let pushClient = pushClient
                return .run { _ in await pushClient.registerForRemoteNotifications() }

            case .becameActive:
                let pushClient = pushClient
                return .concatenate(
                    .run { send in await send(.authorizationRefreshed(await pushClient.authorization())) },
                    reconcile(state: &state)
                )

            case .cleanupRecorded:
                return sweepForgotten()

            case .daemonForgotten(let daemon):
                state.daemons.remove(id: daemon.id)
                state.daemonErrors[daemon.id] = nil
                state.$pendingUnregister.withLock { _ = $0.remove(daemon.id) }
                let (secrets, cleanup) = (secrets, cleanup)
                // Only saves the record: the parent deletes the token right
                // after this effect, and the DELETE runs on its own.
                return .merge(
                    share(state),
                    .run { send in
                        guard let saved = try? secrets.load(daemon.id) else { return }
                        try cleanup.save(ForgottenDaemon(daemon: daemon, secrets: saved))
                        await send(.cleanupRecorded)
                    } catch: { error, _ in
                        LeoLog.logger(category: "push").error("Couldn't keep \(daemon.name, privacy: .public)'s push cleanup record: \(error, privacy: .public)")
                    }
                )

            case .daemonPaired(let daemon):
                state.daemons[id: daemon.id] = daemon
                guard state.isEnabled else { return share(state) }
                // After a first pairing is when asking makes sense.
                return .merge(share(state), authorize(prompting: true), register(daemon, state: state))

            case .daemonReconnected(let id):
                return unregisterPending(only: [id], state: &state)

            case .daemonsLoaded(let daemons):
                state.daemons = IdentifiedArray(daemons, uniquingIDsWith: { $1 })
                state.hasLoadedDaemons = true
                let launch: Effect<Action> = state.isEnabled ? authorize(prompting: !daemons.isEmpty) : .none
                return .merge(share(state), launch, reconcile(state: &state))

            case .daemonUpdated(let id, .success):
                state.daemonErrors[id] = nil
                return .none

            case .daemonUpdated(let id, .failure(let error)):
                guard state.isEnabled, state.daemons[id: id] != nil else { return .none }
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
                state.$pendingUnregister.withLock { $0 = [] }
                state.daemonErrors = [:]
                // The token that answers re-registers everywhere.
                return authorize(prompting: true)

            case .toggled(false):
                state.$isEnabled.withLock { $0 = false }
                // A union: before the pairings load, the list is empty but
                // earlier pending daemons still count.
                state.$pendingUnregister.withLock { $0.formUnion(state.daemons.ids) }
                state.daemonErrors = [:]
                // The daemon's DELETE can't be relied on (off the VPN, the
                // relay is still reachable), so stop APNs delivery here too.
                let pushClient = pushClient
                return .merge(
                    .cancel(id: CancelID.relay),
                    .run { _ in await pushClient.unregisterForRemoteNotifications() },
                    unregisterPending(only: nil, state: &state)
                )

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

            case .unregistered(let id, .success):
                state.$pendingUnregister.withLock { _ = $0.remove(id) }
                state.daemonErrors[id] = nil
                return .none

            case .unregistered(let id, .failure(let error)):
                if Self.isGone(error) {
                    state.$pendingUnregister.withLock { _ = $0.remove(id) }
                    state.daemonErrors[id] = nil
                } else if !state.isEnabled, state.pendingUnregister.contains(id) {
                    state.daemonErrors[id] = Self.message(for: error)
                }
                return .none
            }
        }
    }

    /// Retries every unfinished unregistration: pending daemons while
    /// notifications are off, and forgotten daemons always.
    private func reconcile(state: inout State) -> Effect<Action> {
        .merge(unregisterPending(only: nil, state: &state), sweepForgotten())
    }

    /// DELETEs push from pending daemons (all, or just `only`). Pending IDs
    /// no longer paired are dropped: a forget took over their cleanup.
    /// Does nothing before the pairings load.
    private func unregisterPending(only ids: Set<PairedDaemon.ID>?, state: inout State) -> Effect<Action> {
        // Which daemons are paired isn't known yet; the load reconciles.
        guard state.hasLoadedDaemons else { return .none }
        let paired = Set(state.daemons.ids)
        if !state.pendingUnregister.isSubset(of: paired) {
            state.$pendingUnregister.withLock { $0.formIntersection(paired) }
        }
        guard !state.isEnabled else { return .none }
        let targets = state.daemons.filter { state.pendingUnregister.contains($0.id) && (ids?.contains($0.id) ?? true) }
        return .merge(targets.map(unregister))
    }

    private func unregister(_ daemon: PairedDaemon) -> Effect<Action> {
        let (daemonClient, secrets) = (daemonClient, secrets)
        return .run { send in
            await send(.unregistered(daemon.id, Result {
                guard let saved = try secrets.load(daemon.id) else { throw PushRegistrationError.noToken }
                try await daemonClient.deletePush(DaemonConnection(daemon: daemon, secrets: saved), daemon.deviceID)
            }))
        }
        .cancellable(id: CancelID.daemon(daemon.id), cancelInFlight: true)
    }

    /// DELETEs push from every forgotten daemon with a cleanup record,
    /// dropping each record once the daemon confirms or refuses the device.
    private func sweepForgotten() -> Effect<Action> {
        let (cleanup, daemonClient) = (cleanup, daemonClient)
        return .run { _ in
            let records = try cleanup.load()
            await withTaskGroup(of: Void.self) { group in
                for record in records {
                    group.addTask {
                        do {
                            let connection = DaemonConnection(daemon: record.daemon, secrets: record.secrets)
                            try await daemonClient.deletePush(connection, record.daemon.deviceID)
                        } catch where !Self.isGone(error) {
                            LeoLog.logger(category: "push").info("Push cleanup for forgotten \(record.daemon.name, privacy: .public) will retry: \(error, privacy: .public)")
                            return
                        } catch {}
                        try? cleanup.remove(record.id)
                    }
                }
            }
        } catch: { error, _ in
            LeoLog.logger(category: "push").error("Couldn't read push cleanup records: \(error, privacy: .public)")
        }
        .cancellable(id: CancelID.forgottenSweep, cancelInFlight: true)
    }

    /// The extension shows only pushes from these daemons.
    private func share(_ state: State) -> Effect<Action> {
        let (pushClient, ids) = (pushClient, Set(state.daemons.ids))
        return .run { _ in try pushClient.sharePairedDaemons(ids) } catch: { error, _ in
            LeoLog.logger(category: "push").error("Couldn't share paired daemons with the notification extension: \(error, privacy: .public)")
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

    /// The daemon no longer knows this device (revoked or never had push),
    /// or there's no token left to ask with: nothing more can be unregistered.
    static func isGone(_ error: any Error) -> Bool {
        switch error {
        case LeoDaemonError.daemon(let code, _, _): ["unauthorized", "forbidden", "not_found"].contains(code)
        case PushRegistrationError.noToken: true
        default: false
        }
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
