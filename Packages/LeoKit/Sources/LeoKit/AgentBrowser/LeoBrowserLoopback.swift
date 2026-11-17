import Foundation

/// Which URLs name the agent's own machine rather than a host anyone can
/// reach.
public enum LeoBrowserLoopback {
    /// The hosts a Mac port forward listens on (both loopbacks): a URL on
    /// one of these can be remapped to the forward's local port.
    private static let forwardableHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// Whether `url` is on a loopback host the Mac's port forwards reach.
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return forwardableHosts.contains(host)
    }

    /// Whether `url` can only mean the machine it was typed on: every
    /// loopback form, `127.0.0.0/8`, `*.localhost` and `0.0.0.0`. On a device
    /// other than the agent's machine, these never reach the agent's server.
    public static func isMachineLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return false }
        if isLoopback(url) || host == "::1" || host == "0.0.0.0" { return true }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    /// The plain explanation for a machine-local URL, shown to agents and
    /// users alike.
    public static func unreachableMessage(machine: String) -> String {
        "This page is on \(machine)'s localhost, which Leo on iPhone can't reach. Use an address on your network instead."
    }
}

/// The mapping for a browser that can't reach the agent's machine's
/// localhost (iOS): machine-local URLs are refused with
/// `localhost_unreachable`; every other URL passes unchanged.
@MainActor
public final class LeoLoopbackRefusingURLMapping: LeoBrowserURLMapping {
    public let machine: String

    public init(machine: String) {
        self.machine = machine
    }

    public func toLocal(_ url: URL) async throws -> URL {
        guard !LeoBrowserLoopback.isMachineLocal(url) else {
            throw LeoBrowserError(.localhostUnreachable, LeoBrowserLoopback.unreachableMessage(machine: machine))
        }
        return url
    }

    public func toRemote(_ url: URL) -> URL { url }
}
