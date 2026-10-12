import ComposableArchitecture
import Foundation
import LeoKit
import Security

/// Whether the user lets Leo show notifications.
public enum PushAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

/// The system side of push: notification permission, the APNs token
/// request, and the phone's push key. The app target supplies the live
/// value (it needs UIApplication).
@DependencyClient
public struct PushClient: Sendable {
    public var authorization: @Sendable () async -> PushAuthorization = { .notDetermined }
    /// Shows the system prompt; true when the user allows notifications.
    public var requestAuthorization: @Sendable () async throws -> Bool
    /// Asks APNs for a token; it arrives through the app delegate as
    /// `PushNotifications.Action.tokenReceived`.
    public var registerForRemoteNotifications: @Sendable () async -> Void
    /// Drops the APNs registration, so no push reaches the phone until the
    /// next `registerForRemoteNotifications`.
    public var unregisterForRemoteNotifications: @Sendable () async -> Void
    /// The phone's push key, generated and stored on first use.
    public var key: @Sendable () throws -> LeoPushKey
    /// Tells the Notification Service Extension which daemons are paired;
    /// it leaves pushes from any other daemon generic.
    public var sharePairedDaemons: @Sendable (_ ids: Set<String>) throws -> Void
}

extension PushClient: TestDependencyKey {
    public static let testValue = PushClient()
}

/// The push relay's `POST /register`.
@DependencyClient
public struct PushRelayClient: Sendable {
    /// Trades an APNs token for a grant the daemons push with.
    public var register: @Sendable (_ relayURL: URL, _ apnsToken: Data, _ environment: LeoAPNsEnvironment) async throws -> String
}

extension PushRelayClient: DependencyKey {
    public static let testValue = PushRelayClient()

    public static var liveValue: PushRelayClient {
        let session = URLSession(configuration: .ephemeral)
        return PushRelayClient(register: { relayURL, token, environment in
            try await LeoPushRelay.register(relayURL: relayURL, apnsToken: token, environment: environment, session: session)
        })
    }
}

/// Where this build's pushes go: the relay (built in) and the APNs
/// environment its tokens belong to (sandbox for Debug, production for
/// Release).
public struct PushConfiguration: Equatable, Sendable {
    /// Nil when the build has no usable relay URL.
    public var relayURL: URL?
    public var environment: LeoAPNsEnvironment

    public init(relayURL: URL?, environment: LeoAPNsEnvironment) {
        self.relayURL = relayURL
        self.environment = environment
    }

    /// Reads `LeoPushRelayURL` and `LeoAPNsEnvironment` from an Info.plist.
    /// Only an `https` URL whose host is a plain DNS name counts, so an
    /// unfilled placeholder never receives a token.
    public init(infoDictionary: [String: Any]) {
        environment = (infoDictionary["LeoAPNsEnvironment"] as? String).flatMap(LeoAPNsEnvironment.init(rawValue:)) ?? .production
        relayURL = (infoDictionary["LeoPushRelayURL"] as? String).flatMap(Self.relayURL)
    }

    static func relayURL(_ raw: String) -> URL? {
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), host.contains("."),
              host.unicodeScalars.allSatisfy(hostCharacters.contains),
              components.query == nil, components.fragment == nil else { return nil }
        return components.url
    }
}

extension PushConfiguration: DependencyKey {
    public static var liveValue: PushConfiguration { PushConfiguration(infoDictionary: Bundle.main.infoDictionary ?? [:]) }
    public static let testValue = PushConfiguration(relayURL: URL(string: "https://leo-relay.test.workers.dev"), environment: .sandbox)
}

/// A forgotten daemon whose push registration hasn't been deleted yet: its
/// pairing and this device's token, kept (in the Keychain) only until the
/// daemon confirms the DELETE or shows the device is already revoked.
public struct ForgottenDaemon: Codable, Equatable, Identifiable, Sendable {
    public let daemon: PairedDaemon
    public let secrets: DaemonSecrets

    /// The device ID: unique per pairing, so a re-pair never overwrites it.
    public var id: String { daemon.deviceID }

    public init(daemon: PairedDaemon, secrets: DaemonSecrets) {
        self.daemon = daemon
        self.secrets = secrets
    }
}

/// Forgotten daemons still to unregister push from.
@DependencyClient
public struct PushCleanupClient: Sendable {
    public var load: @Sendable () throws -> [ForgottenDaemon]
    public var save: @Sendable (_ record: ForgottenDaemon) throws -> Void
    public var remove: @Sendable (_ id: ForgottenDaemon.ID) throws -> Void
}

extension PushCleanupClient: DependencyKey {
    public static let testValue = PushCleanupClient()

    /// One generic password per record, this device only, after first unlock.
    public static var liveValue: PushCleanupClient {
        let service = "studio.blackpaw.leo.ios.push-cleanup"
        @Sendable func query(_ id: String? = nil) -> [String: Any] {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            if let id { query[kSecAttrAccount as String] = id }
            return query
        }
        return PushCleanupClient(
            load: {
                var lookup = query()
                lookup[kSecReturnData as String] = true
                lookup[kSecMatchLimit as String] = kSecMatchLimitAll
                var result: AnyObject?
                let status = SecItemCopyMatching(lookup as CFDictionary, &result)
                if status == errSecItemNotFound { return [] }
                guard status == errSecSuccess, let items = result as? [Data] else { throw KeychainError(status: status) }
                return items.compactMap { try? JSONDecoder().decode(ForgottenDaemon.self, from: $0) }
            },
            save: { record in
                let attributes: [String: Any] = [
                    kSecValueData as String: try JSONEncoder().encode(record),
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]
                var status = SecItemUpdate(query(record.id) as CFDictionary, attributes as CFDictionary)
                if status == errSecItemNotFound {
                    status = SecItemAdd(query(record.id).merging(attributes) { $1 } as CFDictionary, nil)
                }
                guard status == errSecSuccess else { throw KeychainError(status: status) }
            },
            remove: { id in
                let status = SecItemDelete(query(id) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            }
        )
    }
}

extension SharedKey where Self == FileStorageKey<Set<String>>.Default {
    /// Paired daemons still to unregister after notifications were turned
    /// off (IDs only; their tokens are in the Keychain with the pairing).
    public static var pushPendingUnregister: Self {
        Self[.fileStorage(.applicationSupportDirectory.appending(path: "push-pending-unregister.json")), default: []]
    }
}

extension SharedKey where Self == AppStorageKey<Bool>.Default {
    /// The Settings switch; on until the user turns it off.
    public static var notificationsEnabled: Self { Self[.appStorage("notificationsEnabled"), default: true] }
}

extension DependencyValues {
    public var pushClient: PushClient {
        get { self[PushClient.self] }
        set { self[PushClient.self] = newValue }
    }

    public var pushRelay: PushRelayClient {
        get { self[PushRelayClient.self] }
        set { self[PushRelayClient.self] = newValue }
    }

    public var pushCleanup: PushCleanupClient {
        get { self[PushCleanupClient.self] }
        set { self[PushCleanupClient.self] = newValue }
    }

    public var pushConfiguration: PushConfiguration {
        get { self[PushConfiguration.self] }
        set { self[PushConfiguration.self] = newValue }
    }
}
