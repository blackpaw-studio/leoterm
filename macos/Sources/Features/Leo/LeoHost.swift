import Foundation

/// A leo host as reported by `leo host list --json`. One synthesized
/// `localhost` entry (the local daemon) is always present; the rest are
/// SSH-reachable remotes from `client.hosts` in `leo.yaml`.
///
/// Remote hosts are reached by SSH (see `LeoForwardManager`), never a network
/// API — the daemon socket stays local-only on every machine.
struct LeoHost: Codable, Equatable, Identifiable, Sendable {
    let name: String
    /// SSH target (e.g. `leo@10.0.2.10`); `nil` for `localhost`.
    let ssh: String?
    let isDefault: Bool
    let isLocal: Bool

    var id: String { name }

    /// A remote host requires an SSH forward for the control plane and an
    /// `--host` flag on cell/CLI dispatch; the local host needs neither.
    var isRemote: Bool { !isLocal }

    /// The synthesized local-daemon host name, matching the daemon's
    /// `host list` convention.
    static let localhostName = "localhost"

    enum CodingKeys: String, CodingKey {
        case name, ssh
        case isDefault = "default"
        case isLocal = "local"
    }
}
