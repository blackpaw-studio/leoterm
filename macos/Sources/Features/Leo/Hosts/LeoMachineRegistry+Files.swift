import Foundation
import LeoKit

extension LeoMachineRegistry {
    /// File access for `host`: the local filesystem for This Mac; for a
    /// remote machine, SFTP sessions multiplexed over that machine's own
    /// tunnel's ControlMaster (never a connection of their own: with the
    /// tunnel down, operations fail with `.disconnected`). Any enabled
    /// machine works, since each has its own tunnel. Throws `.disconnected`
    /// for a machine that is no longer configured or is disabled, and
    /// `.unavailable` when the tunnel runs without a master or its master's
    /// socket has vanished -- recovered by reconnecting, never automatically.
    func makeFileAccess(for host: LeoHostID) throws -> any LeoFileAccess {
        guard case .remote = host else { return LeoFileAccessor.local() }
        guard let configuration = configuration(for: host), configuration.isEnabled else {
            throw LeoFileAccessError.disconnected
        }
        let path = environment.controlPath(for: configuration)
        guard LeoSSHCommand.isValidControlPath(path) else {
            throw LeoFileAccessError.unavailable(reason: Self.unsupportedControlPath)
        }
        // A master in a directory another user controls would see every
        // file this session reads or writes.
        do {
            try LeoControlSocketDirectory.prepare(environment.controlSocketDirectory)
        } catch {
            throw LeoFileAccessError.unavailable(reason: Self.unsafeControlDirectory)
        }
        switch LeoControlSocket.inspect(path, owner: environment.controlSocketOwner) {
        case .notASocket: throw LeoFileAccessError.unavailable(reason: Self.occupiedControlPath)
        case .foreign: throw LeoFileAccessError.unavailable(reason: Self.foreignControlSocket)
        case .absent where status(for: host) == .connected: throw LeoFileAccessError.unavailable(reason: Self.missingControlSocket)
        case .absent, .live, .stale, .unknown: break
        }
        let command = LeoSSHCommand(configuration: configuration)
        let launcher = LeoSFTPProcessLauncher(
            executable: environment.sshExecutable,
            arguments: try command.sftpArguments(controlPath: path),
            fallbackArguments: try command.sftpBootstrapArguments(controlPath: path)
        )
        return LeoFileAccessor.sftp(launcher: launcher)
    }

    static let unsupportedControlPath: LeoFileAccessReason = "control path unsupported"
    static let occupiedControlPath: LeoFileAccessReason = "control path is occupied"
    static let unsafeControlDirectory: LeoFileAccessReason = "control directory is not private"
    static let foreignControlSocket: LeoFileAccessReason = "the control socket belongs to another user"
    static let missingControlSocket: LeoFileAccessReason = "the connection’s control socket is gone. Reconnect to restore file access"
}
