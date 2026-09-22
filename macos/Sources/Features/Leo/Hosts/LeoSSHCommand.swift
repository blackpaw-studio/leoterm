import Foundation

enum LeoSSHCommandError: Error, Equatable, Sendable {
    case invalidConfiguration([LeoHostValidationError])
    case invalidSocketPath
    case invalidControlPath
}

struct LeoSSHCommand: Sendable {
    let configuration: LeoHostConfiguration

    /// The tunnel process is also the host's ControlMaster, listening on
    /// `controlPath` (an app-owned path, never the user's own master), so
    /// SFTP sessions multiplex over this one connection and die with it.
    /// `ControlPersist=no` keeps the master in this process instead of
    /// letting a user config fork it into the background.
    func tunnelArguments(localSocketPath: String, remoteSocketPath: String, controlPath: String) throws -> [String] {
        try validateConfiguration()
        try validateLocalSocketPath(localSocketPath)
        try validateSocketPath(remoteSocketPath)
        try validateControlPath(controlPath)
        var arguments = [
            "-n", "-N",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=yes",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=no",
            "-o", "StreamLocalBindUnlink=yes"
        ]
        appendIdentityAndPort(to: &arguments)
        arguments += ["-L", "\(localSocketPath):\(remoteSocketPath)", target]
        return arguments
    }

    /// `ssh -s <target> sftp` as a mux client of the tunnel's master at
    /// `controlPath`. ssh tries the ControlPath before dialling; with the
    /// master gone it would open a fresh connection, which
    /// `ProxyCommand=/usr/bin/false` turns into an immediate failure
    /// instead. `-T`: a pty would corrupt the binary protocol.
    /// `ClearAllForwardings`: a user config's forwards must not be
    /// re-requested on every session.
    func sftpArguments(controlPath: String) throws -> [String] {
        try validateConfiguration()
        try validateControlPath(controlPath)
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ProxyCommand=/usr/bin/false",
            "-o", "ClearAllForwardings=yes"
        ]
        appendIdentityAndPort(to: &arguments)
        arguments += ["-s", target, "sftp"]
        return arguments
    }

    func execArguments(remoteCommand: [String]) throws -> [String] {
        try validateConfiguration()
        var arguments = ["-o", "BatchMode=yes"]
        appendIdentityAndPort(to: &arguments)
        arguments += [target, try remoteCommand.map(remoteArgument).joined(separator: " ")]
        return arguments
    }

    /// `env -u TMUX -u TMUX_PANE` prefix matches the local attach command
    /// (`LeoAttachCommand.build`): the new tab must not inherit the
    /// surrounding tmux session's `TMUX`/`TMUX_PANE`.
    func attachShellCommand(agent: String) throws -> String {
        try validateConfiguration()
        var parts = ["env", "-u", "TMUX", "-u", "TMUX_PANE", "ssh", "-t"]
        if let identityFile = configuration.identityFile {
            parts += ["-i", try leoShellQuote(identityFile)]
        }
        if let port = configuration.port {
            parts += ["-p", try leoShellQuote(String(port))]
        }
        parts += [try leoShellQuote(target), try leoShellQuote(remoteAttachCommand(agent: agent))]
        return parts.joined(separator: " ")
    }

    func remoteAttachCommand(agent: String) throws -> String {
        try validateConfiguration()
        return "\(try remoteLeoCommand()) agent attach -- \(try leoShellQuote(agent))"
    }

    /// No `env -u TMUX ...` prefix, matching the local logs command
    /// (`LeoLogsCommand.build`) -- logs is a one-shot stream, not a tmux
    /// attach, so there's nothing to unset.
    func logsShellCommand(agent: String) throws -> String {
        try validateConfiguration()
        var parts = ["ssh", "-t"]
        if let identityFile = configuration.identityFile {
            parts += ["-i", try leoShellQuote(identityFile)]
        }
        if let port = configuration.port {
            parts += ["-p", try leoShellQuote(String(port))]
        }
        parts += [try leoShellQuote(target), try leoShellQuote(remoteLogsCommand(agent: agent))]
        return parts.joined(separator: " ")
    }

    func remoteLogsCommand(agent: String) throws -> String {
        try validateConfiguration()
        return "\(try remoteLeoCommand()) agent logs -f -- \(try leoShellQuote(agent))"
    }

    func remoteHomeCommand() throws -> [String] {
        try validateConfiguration()
        var arguments = ["-o", "BatchMode=yes"]
        appendIdentityAndPort(to: &arguments)
        arguments += [target, "printf %s \"$HOME\""]
        return arguments
    }

    func resolvedRemoteSocketPath(home: String) throws -> String {
        try validateConfiguration()
        let path: String
        if configuration.remoteSocketPath.hasPrefix("~/") {
            path = home + configuration.remoteSocketPath.dropFirst()
        } else {
            path = configuration.remoteSocketPath
        }
        try validateSocketPath(path)
        guard path.hasPrefix("/") else { throw LeoSSHCommandError.invalidSocketPath }
        return path
    }

    private var target: String {
        if let user = configuration.user { return "\(user)@\(configuration.host)" }
        return configuration.host
    }

    private func appendIdentityAndPort(to arguments: inout [String]) {
        if let identityFile = configuration.identityFile {
            arguments += ["-i", identityFile]
        }
        if let port = configuration.port {
            arguments += ["-p", String(port)]
        }
    }

    private func remoteArgument(_ argument: String) throws -> String {
        if argument == configuration.remoteLeoPath {
            return try remoteLeoCommand()
        }
        return try leoShellQuote(argument)
    }

    private func remoteLeoCommand() throws -> String {
        guard configuration.remoteLeoPath.hasPrefix("~/") else {
            return try leoShellQuote(configuration.remoteLeoPath)
        }
        return "~/" + (try leoShellQuote(String(configuration.remoteLeoPath.dropFirst(2))))
    }

    private func validateSocketPath(_ path: String) throws {
        guard !path.isEmpty, !path.contains(":"), !path.contains("\0") else {
            throw LeoSSHCommandError.invalidSocketPath
        }
    }

    private func validateLocalSocketPath(_ path: String) throws {
        try validateSocketPath(path)
        guard path.utf8.count <= 100 else { throw LeoSSHCommandError.invalidSocketPath }
    }

    /// ssh binds `<ControlPath>.<16 random chars>` before renaming it into
    /// place, so the path gets 104 - 1 (NUL) - 17 = 86 bytes. Only
    /// characters ssh's `-o` parser and `%`-token expansion pass through
    /// untouched are allowed.
    private func validateControlPath(_ path: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._+-")
        guard path.hasPrefix("/"), path.utf8.count <= 86,
              path.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw LeoSSHCommandError.invalidControlPath
        }
    }

    private func validateConfiguration() throws {
        let errors = configuration.validate()
        guard errors.isEmpty else { throw LeoSSHCommandError.invalidConfiguration(errors) }
    }
}
