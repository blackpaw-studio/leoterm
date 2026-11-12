import Foundation
import LeoKit

/// How an agent's drawer shell starts.
enum LeoDrawerShellLaunch: Equatable {
    /// The user's login shell, in this directory.
    case local(workingDirectory: String)
    /// A command that reaches the agent's machine (an `ssh -t` running its `agent shell`).
    case remote(command: String)
    /// Nothing is spawned; the body says why.
    case unavailable(String)
}

/// Chooses the drawer shell's launch for an agent. Pure: the filesystem, the
/// remote command builder and the host's state come in as arguments.
enum LeoDrawerShellLauncher {
    static func choose(
        identity: LeoAgentIdentity,
        features: LeoDaemonFeatures,
        isConnected: Bool,
        home: String,
        isDirectory: (String) -> Bool = LeoRestoredWorkingDirectory.isDirectory,
        remoteCommand: (LeoAgentIdentity) throws -> String
    ) -> LeoDrawerShellLaunch {
        switch identity.host {
        case .local:
            return .local(
                workingDirectory: LeoAttachCommand.workingDirectory(identity: identity, isDirectory: isDirectory) ?? home)
        case .remote(let machine):
            guard isConnected else { return .unavailable("\(machine) isn't connected.") }
            guard features.contains(.agentShell) else {
                return .unavailable("Terminals for agents on \(machine) need a newer Leo on that machine.")
            }
            do {
                return .remote(command: try remoteCommand(identity))
            } catch {
                return .unavailable("Couldn't start a terminal on \(machine): \(error.localizedDescription)")
            }
        }
    }
}
