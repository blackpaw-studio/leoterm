import Foundation

/// The Daemon pane's shared rules: the service (status, actions, log), the
/// web UI form, the remote client form and the remote hosts, in that order.
///
/// The client's `default_host` picks from the hosts, and follows them as they
/// are added and deleted. The daemon doesn't treat it as a foreign key:
/// deleting the default host leaves the setting as it was, which the delete
/// confirmation says.
public enum LeoDaemonPane {
    public enum Section: String, CaseIterable, Hashable, Sendable {
        case service, web, client, hosts
    }

    public static let webKey = "web"
    public static let clientKey = "client"
    public static let hostsKey = "hosts"
    public static let defaultHostKey = "default_host"

    /// The client resource as the pane draws it: `default_host` picks from the hosts.
    @Sendable public static func clientResource(_ resource: LeoConfigResource) -> LeoConfigResource {
        resource.referencing(defaultHostKey, to: hostsKey, emptyLabel: "None")
    }

    /// The names the client form picks its default host from.
    public static func hostReferences(_ hosts: [LeoConfigItem]) -> [String: [String]] {
        [hostsKey: hosts.map(\.name)]
    }

    /// What deleting `host` also means, when it is more than removing the
    /// host: the client's default host is left naming it.
    public static func deleteNote(forHost host: String, client: LeoConfigDraft?) -> String? {
        guard client?.document.values[defaultHostKey]?.stringValue == host else { return nil }
        return "It is the default host. The default host setting stays set to it until you change it."
    }
}
