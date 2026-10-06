import Foundation

extension LeoHostSelection {
    /// File access for the selected host: the local filesystem for
    /// localhost; for a remote host, SFTP sessions multiplexed over the
    /// tunnel's ControlMaster (never a connection of their own -- with the
    /// tunnel down, operations fail with `.disconnected`). Throws
    /// `.disconnected` when the selected remote host is no longer configured,
    /// and `.unavailable` when the tunnel runs without a master (see
    /// `multiplexingControlPath(for:)`) or its master's socket has vanished
    /// (the OS can purge the cache directory under it) -- recovered by
    /// reconnecting, never automatically.
    func makeFileAccess() throws -> any LeoFileAccess {
        guard case .remote(let name) = selected else { return LeoFileAccessor.local() }
        guard let configuration = hosts.first(where: { $0.name == name }) else { throw LeoFileAccessError.disconnected }
        let path = controlPath(for: configuration)
        guard LeoSSHCommand.isValidControlPath(path) else {
            throw LeoFileAccessError.unavailable(reason: Self.unsupportedControlPath)
        }
        // A master in a directory another user controls would see every
        // file this session reads or writes.
        do {
            try LeoControlSocketDirectory.prepare(controlSocketDirectory)
        } catch {
            throw LeoFileAccessError.unavailable(reason: Self.unsafeControlDirectory)
        }
        switch LeoControlSocket.inspect(path, owner: controlSocketOwner) {
        case .notASocket: throw LeoFileAccessError.unavailable(reason: Self.occupiedControlPath)
        case .foreign: throw LeoFileAccessError.unavailable(reason: Self.foreignControlSocket)
        case .absent where isConnected: throw LeoFileAccessError.unavailable(reason: Self.missingControlSocket)
        case .absent, .live, .stale, .unknown: break
        }
        let command = LeoSSHCommand(configuration: configuration)
        let launcher = LeoSFTPProcessLauncher(
            executable: sshExecutable,
            arguments: try command.sftpArguments(controlPath: path),
            fallbackArguments: try command.sftpBootstrapArguments(controlPath: path)
        )
        return LeoFileAccessor.sftp(launcher: launcher)
    }

    /// File access for `host`, which must be the selected host: only it has
    /// a tunnel (one host at a time, D-008).
    func makeFileAccess(for host: LeoHostID) throws -> any LeoFileAccess {
        guard host == selected else {
            throw LeoFileAccessError.unavailable(
                reason: "Leo is connected to \(selected.displayName), not \(host.displayName). Switch hosts to open this file"
            )
        }
        return try makeFileAccess()
    }

    /// The tunnel's ControlMaster socket for `configuration`, in the
    /// owner-only `controlSocketDirectory` (short whatever the home
    /// directory; see `LeoControlSocketDirectory`), scoped to this app
    /// bundle. SFTP sessions for the host multiplex over it.
    func controlPath(for configuration: LeoHostConfiguration) -> String {
        controlSocketDirectory.appendingPathComponent(configuration.controlSocketFileName(instance: controlSocketInstance)).path
    }

    /// The control path the tunnel should listen on, or nil to run it
    /// without a master: when ssh can't use the path (a directory with a
    /// space or non-ASCII characters, or one too long), when the directory
    /// isn't provably private, or when something other than a socket -- or
    /// another user's socket -- occupies it. A socket a master that
    /// died without cleanup left behind is removed first -- otherwise
    /// `ControlMaster=yes` would run without multiplexing rather than
    /// replace it. A live socket is left alone (ssh then disables its own
    /// master and SFTP multiplexes over the listener). Called only after
    /// the previous tunnel's teardown barrier has resolved.
    func multiplexingControlPath(for configuration: LeoHostConfiguration) -> String? {
        let path = controlPath(for: configuration)
        guard LeoSSHCommand.isValidControlPath(path) else {
            Self.logger.error("control path unsupported by ssh; tunnel runs without file access path=\(path, privacy: .public)")
            return nil
        }
        do {
            try LeoControlSocketDirectory.prepare(controlSocketDirectory)
        } catch {
            Self.logger.error("control directory not private; tunnel runs without file access path=\(path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
        switch LeoControlSocket.removeIfStale(path, owner: controlSocketOwner) {
        case .absent, .stale:
            return path
        case .live:
            Self.logger.log("control socket already live; leaving it path=\(path, privacy: .public)")
            return path
        case .notASocket:
            Self.logger.error("control path occupied by a non-socket; leaving it, tunnel runs without file access path=\(path, privacy: .public)")
            return nil
        case .foreign:
            Self.logger.error("control socket owned by another user; leaving it, tunnel runs without file access path=\(path, privacy: .public)")
            return nil
        case .unknown(let code):
            Self.logger.error("control socket check failed; leaving it path=\(path, privacy: .public) errno=\(code)")
            return path
        }
    }

    static let unsupportedControlPath: LeoFileAccessReason = "control path unsupported"
    static let occupiedControlPath: LeoFileAccessReason = "control path is occupied"
    static let unsafeControlDirectory: LeoFileAccessReason = "control directory is not private"
    static let foreignControlSocket: LeoFileAccessReason = "the control socket belongs to another user"
    static let missingControlSocket: LeoFileAccessReason = "the connection’s control socket is gone. Reconnect to restore file access"

    private var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }
}
