import ComposableArchitecture
import Foundation
import LeoKit

/// A paired daemon's JSON config API, and the per-daemon record of which
/// revisions this app's own writes superseded. One tracker per daemon is
/// shared by every pane open on it, so a Template save isn't a conflict for
/// the Environments pane that read the file just before.
public struct ConfigClients: Sendable {
    public var client: @Sendable (_ connection: DaemonConnection) -> any LeoConfigClient
    public var revisions: @Sendable (_ daemonID: String) -> LeoConfigRevisionTracker

    public init(
        client: @escaping @Sendable (DaemonConnection) -> any LeoConfigClient,
        revisions: @escaping @Sendable (String) -> LeoConfigRevisionTracker = ConfigClients.trackers()
    ) {
        self.client = client
        self.revisions = revisions
    }

    /// A tracker per daemon ID, made on first use.
    public static func trackers() -> @Sendable (String) -> LeoConfigRevisionTracker {
        let trackers = LockIsolated<[String: LeoConfigRevisionTracker]>([:])
        return { daemonID in
            trackers.withValue { known in
                if let tracker = known[daemonID] { return tracker }
                let tracker = LeoConfigRevisionTracker()
                known[daemonID] = tracker
                return tracker
            }
        }
    }
}

extension ConfigClients: DependencyKey {
    /// Every test names the client it wants: an unnamed one is a test failure.
    public static var testValue: ConfigClients {
        ConfigClients(client: { _ in
            reportIssue("ConfigClients.client is unimplemented")
            return LeoFakeConfigClient(schema: LeoConfigSchema(resources: []))
        })
    }

    public static var liveValue: ConfigClients {
        let session = URLSession(configuration: .default)
        return ConfigClients(client: { connection in
            LeoWebDaemonClient(transport: LeoHTTPSTransport(endpoint: connection.endpoint, session: session)).configClient()
        })
    }
}

extension DependencyValues {
    public var configClients: ConfigClients {
        get { self[ConfigClients.self] }
        set { self[ConfigClients.self] = newValue }
    }
}
