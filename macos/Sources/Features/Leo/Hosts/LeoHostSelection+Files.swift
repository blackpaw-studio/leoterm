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
}
