import Foundation

/// Translates between the URLs an agent uses and the ones its web view loads.
/// For a remote machine, an agent's `http://localhost:5173` is the remote
/// machine's port; the web view loads it through a local port forward.
/// Agents only ever see remote terms.
@MainActor
public protocol LeoBrowserURLMapping: AnyObject {
    /// The URL to hand the web view for an agent-supplied `url` (remote terms),
    /// starting a port forward when one is needed. Throws `navigation_failed`
    /// when the forward cannot be set up. URLs that need no mapping come back unchanged.
    func toLocal(_ url: URL) async throws -> URL

    /// The remote-terms URL for one the web view reports, for showing to the
    /// agent and the URL bar. Pure: never opens a forward. Unmapped URLs come back unchanged.
    func toRemote(_ url: URL) -> URL
}

/// The mapping for a browser that needs none (the local machine).
@MainActor
public final class LeoIdentityURLMapping: LeoBrowserURLMapping {
    public init() {}

    public func toLocal(_ url: URL) async throws -> URL { url }
    public func toRemote(_ url: URL) -> URL { url }
}
