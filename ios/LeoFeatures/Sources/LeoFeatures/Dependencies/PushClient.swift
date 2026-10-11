import ComposableArchitecture
import Foundation
import LeoKit

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
    /// The phone's push key, generated and stored on first use.
    public var key: @Sendable () throws -> LeoPushKey
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

    public var pushConfiguration: PushConfiguration {
        get { self[PushConfiguration.self] }
        set { self[PushConfiguration.self] = newValue }
    }
}
