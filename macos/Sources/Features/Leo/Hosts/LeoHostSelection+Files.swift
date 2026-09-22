import Foundation

extension LeoHostSelection {
    /// File access for the selected host: the local filesystem for
    /// localhost; for a remote host, SFTP sessions multiplexed over the
    /// tunnel's ControlMaster (never a connection of their own -- with the
    /// tunnel down, operations fail with `.disconnected`). Throws
    /// `.disconnected` when the selected remote host is no longer configured,
    /// and `.unavailable` when the tunnel runs without a master (see
    /// `multiplexingControlPath(for:)`).
    func makeFileAccess() throws -> any LeoFileAccess {
        guard case .remote(let name) = selected else { return LeoFileAccessor.local() }
        guard let configuration = hosts.first(where: { $0.name == name }) else { throw LeoFileAccessError.disconnected }
        let path = controlPath(for: configuration)
        guard LeoSSHCommand.isValidControlPath(path) else {
            throw LeoFileAccessError.unavailable(reason: Self.unsupportedControlPath)
        }
        guard LeoControlSocket.inspect(path) != .notASocket else {
            throw LeoFileAccessError.unavailable(reason: Self.occupiedControlPath)
        }
        let arguments = try LeoSSHCommand(configuration: configuration).sftpArguments(controlPath: path)
        return LeoFileAccessor.sftp(launcher: LeoSFTPProcessLauncher(executable: sshExecutable, arguments: arguments))
    }

    /// The tunnel's ControlMaster socket for `configuration`, beside its
    /// forwarded socket in the owner-only directory, scoped to this app
    /// bundle. SFTP sessions for the host multiplex over it.
    func controlPath(for configuration: LeoHostConfiguration) -> String {
        localSocketDirectory.appendingPathComponent(configuration.controlSocketFileName(instance: controlSocketInstance)).path
    }

    /// The control path the tunnel should listen on, or nil to run it
    /// without a master: when ssh can't use the path (a home directory
    /// with a space or non-ASCII characters, or one too long), or when
    /// something other than a socket occupies it. A socket a master that
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
        switch LeoControlSocket.removeIfStale(path) {
        case .absent, .stale:
            return path
        case .live:
            Self.logger.log("control socket already live; leaving it path=\(path, privacy: .public)")
            return path
        case .notASocket:
            Self.logger.error("control path occupied by a non-socket; leaving it, tunnel runs without file access path=\(path, privacy: .public)")
            return nil
        case .unknown(let code):
            Self.logger.error("control socket check failed; leaving it path=\(path, privacy: .public) errno=\(code)")
            return path
        }
    }

    static let unsupportedControlPath = "control path unsupported"
    static let occupiedControlPath = "control path is occupied"
}
