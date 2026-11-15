import Foundation

/// The connection state of one machine. This Mac is always `.connected` to
/// the local daemon socket; a remote machine's state reflects the app-owned
/// SSH tunnel its connection manages.
enum LeoHostConnectionState: Equatable, Sendable {
    case connecting
    case connected(socketPath: String)
    case failed(message: String, hint: String?)

    var failureHint: String? {
        if case .failed(_, let hint) = self { hint } else { nil }
    }
}

enum LeoHostSelectionError: Error, Equatable, Sendable {
    case homeResolutionFailed(String)
    /// The socket directory failed `LeoControlSocketDirectory.prepare`.
    case unsafeSocketDirectory
    /// Another user's socket sits at the forwarded socket's path.
    case foreignTunnelSocket
    /// A file, directory or symlink sits at the forwarded socket's path.
    case occupiedTunnelSocketPath
}

extension LeoHostSelectionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .homeResolutionFailed(let stderr): return stderr
        case .unsafeSocketDirectory: return "The tunnel socket directory is not private"
        case .foreignTunnelSocket: return "The tunnel socket belongs to another user"
        case .occupiedTunnelSocketPath: return "Something other than a socket is at the tunnel socket path"
        }
    }
}

/// Thread-safe box for the orphan record a tunnel's `onExit` (fired off the
/// main actor) needs to clear once the process it describes has exited.
final class LeoTunnelOrphanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: LeoTunnelOrphanRecord?
    var value: LeoTunnelOrphanRecord? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
