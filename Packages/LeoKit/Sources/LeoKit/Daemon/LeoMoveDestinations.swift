import Foundation

/// Where an agent can be moved or copied to: the keys of the source
/// daemon's `client.hosts`. They name hosts as that daemon knows them, which
/// may differ from the app's machine names.
public enum LeoMoveDestinations: Equatable, Sendable {
    case hosts([String])
    /// The host list could not be read; menus show an "Unavailable" placeholder.
    case unavailable

    static let localhost = "localhost"

    /// `hosts` sorted, without `localhost` (Duplicate covers the agent's own
    /// host); nil, a failed read, is `.unavailable`.
    public static func entries(hosts: [String]?) -> Self {
        guard let hosts else { return .unavailable }
        let others = hosts.filter { $0 != localhost }
        return .hosts(others.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    public static func load(_ fetch: () async throws -> [String]) async -> Self {
        entries(hosts: try? await fetch())
    }

    /// The names in `client`'s daemon config `hosts` collection.
    public static func load(from client: any LeoDaemonClient) async -> Self {
        await load {
            guard let config = client.configClient() else { throw LeoDaemonError.transport("Host list is unavailable") }
            return try await config.collection("hosts").items.map(\.name)
        }
    }
}
