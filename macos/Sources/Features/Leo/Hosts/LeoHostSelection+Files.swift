import Foundation

extension LeoHostSelection {
    /// File access for the selected host: the local filesystem for
    /// localhost; for a remote host, SFTP sessions multiplexed over the
    /// tunnel's ControlMaster (never a connection of their own -- with the
    /// tunnel down, operations fail with `.disconnected`). Throws
    /// `.disconnected` when the selected remote host is no longer configured.
    func makeFileAccess() throws -> any LeoFileAccess {
        guard case .remote(let name) = selected else { return LeoFileAccessor.local() }
        guard let configuration = hosts.first(where: { $0.name == name }) else { throw LeoFileAccessError.disconnected }
        let arguments = try LeoSSHCommand(configuration: configuration).sftpArguments(controlPath: controlPath(for: configuration))
        return LeoFileAccessor.sftp(launcher: LeoSFTPProcessLauncher(executable: sshExecutable, arguments: arguments))
    }

    /// The tunnel's ControlMaster socket for `configuration`, beside its
    /// forwarded socket in the owner-only directory. SFTP sessions for the
    /// host multiplex over it.
    func controlPath(for configuration: LeoHostConfiguration) -> String {
        localSocketDirectory.appendingPathComponent(configuration.controlSocketFileName).path
    }

    /// A master that died without cleanup (crash, SIGKILL) leaves its socket
    /// behind, and `ControlMaster=yes` then runs without multiplexing rather
    /// than replace it. Safe to remove: `connect` calls this only after the
    /// previous tunnel's teardown barrier has resolved.
    func removeStaleControlSocket(at path: String) {
        guard fileManager.fileExists(atPath: path) else { return }
        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            Self.logger.error("stale control socket removal failed path=\(path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
