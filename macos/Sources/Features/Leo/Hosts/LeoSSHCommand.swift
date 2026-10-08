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
    /// letting a user config fork it into the background. A nil
    /// `controlPath` (one ssh can't use, or one occupied by something that
    /// isn't a socket) runs the tunnel without multiplexing at all --
    /// `ControlPath=none` also overrides a user config's own -- so the
    /// tunnel still works and only file access is lost.
    func tunnelArguments(localSocketPath: String, remoteSocketPath: String, controlPath: String?) throws -> [String] {
        try validateConfiguration()
        try validateLocalSocketPath(localSocketPath)
        try validateSocketPath(remoteSocketPath)
        var arguments = [
            "-n", "-N",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3"
        ]
        if let controlPath {
            try validateControlPath(controlPath)
            arguments += ["-o", "ControlMaster=yes", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=no"]
        } else {
            arguments += ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
        }
        arguments += ["-o", "StreamLocalBindUnlink=yes"]
        appendIdentityAndPort(to: &arguments)
        arguments += ["-L", "\(localSocketPath):\(remoteSocketPath)", target]
        return arguments
    }

    /// `ssh -s <target> sftp` as a mux client of the tunnel's master at
    /// `controlPath`. ssh tries the ControlPath before dialling; with the
    /// master gone it would open a fresh connection, which
    /// `ProxyCommand=/usr/bin/false` turns into an immediate failure
    /// instead. `-T`: a pty would corrupt the binary protocol.
    /// The rest are the overrides OpenSSH's own `sftp(1)` passes, so a user
    /// config can't break or widen the session: `ClearAllForwardings` (its
    /// forwards -- including the tunnel's -- are not re-requested per
    /// session), `RemoteCommand=none` (it would replace the subsystem),
    /// no agent or X11 forwarding, and no `LocalCommand`.
    func sftpArguments(controlPath: String) throws -> [String] {
        var arguments = try sftpClientArguments(controlPath: controlPath)
        arguments += ["-s", target, "sftp"]
        return arguments
    }

    /// Fallback when sshd explicitly rejects its SFTP subsystem: starts a
    /// fixed server command through the same ControlMaster. The command
    /// checks standard macOS, BSD, and Linux paths without interpolating
    /// configuration or other user-controlled shell text.
    func sftpBootstrapArguments(controlPath: String) throws -> [String] {
        var arguments = try sftpClientArguments(controlPath: controlPath)
        arguments += [target, Self.sftpServerBootstrapCommand]
        return arguments
    }

    private func sftpClientArguments(controlPath: String) throws -> [String] {
        try validateConfiguration()
        try validateControlPath(controlPath)
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ProxyCommand=/usr/bin/false",
            "-o", "ClearAllForwardings=yes",
            "-o", "RemoteCommand=none",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "PermitLocalCommand=no"
        ]
        appendIdentityAndPort(to: &arguments)
        return arguments
    }

    /// The marker lets the local process boundary distinguish a missing
    /// server from an ssh failure (which exits 255). Keep both strings
    /// fixed: remote shell input must never contain host configuration,
    /// paths supplied by the user, or file names.
    static let missingSFTPServerMarker = "leo: no supported sftp-server found"
    static let sftpServerBootstrapCommand = "exec /bin/sh -c 'if [ -x /usr/libexec/sftp-server ]; then exec /usr/libexec/sftp-server; elif [ -x /usr/lib/openssh/sftp-server ]; then exec /usr/lib/openssh/sftp-server; elif [ -x /usr/libexec/openssh/sftp-server ]; then exec /usr/libexec/openssh/sftp-server; elif [ -x /usr/lib/ssh/sftp-server ]; then exec /usr/lib/ssh/sftp-server; elif [ -x /usr/local/libexec/sftp-server ]; then exec /usr/local/libexec/sftp-server; else printf \"%s\\n\" \"leo: no supported sftp-server found\" >&2; exit 127; fi'"

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

    /// `attachShellCommand` for a dispatch subagent (B-266). The remote leo
    /// is local to that host, so no `--host`.
    func attachShellCommand(dispatchID: String) throws -> String {
        try validateConfiguration()
        guard !dispatchID.isEmpty, !dispatchID.hasPrefix("-"),
              !dispatchID.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            throw LeoAttachCommandError.invalidDispatchID
        }
        var parts = ["env", "-u", "TMUX", "-u", "TMUX_PANE", "ssh", "-t"]
        if let identityFile = configuration.identityFile {
            parts += ["-i", try leoShellQuote(identityFile)]
        }
        if let port = configuration.port {
            parts += ["-p", try leoShellQuote(String(port))]
        }
        parts += [try leoShellQuote(target), try leoShellQuote("\(try remoteLeoCommand()) dispatch attach \(try leoShellQuote(dispatchID))")]
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
    static func isValidControlPath(_ path: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._+-")
        return path.hasPrefix("/") && path.utf8.count <= 86 && path.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func validateControlPath(_ path: String) throws {
        guard Self.isValidControlPath(path) else { throw LeoSSHCommandError.invalidControlPath }
    }

    private func validateConfiguration() throws {
        let errors = configuration.validate()
        guard errors.isEmpty else { throw LeoSSHCommandError.invalidConfiguration(errors) }
    }
}
