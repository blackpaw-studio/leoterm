import Foundation

enum LeoSSHCommandError: Error, Equatable, Sendable {
    case invalidConfiguration([LeoHostValidationError])
    case invalidSocketPath
}

struct LeoSSHCommand: Sendable {
    let configuration: LeoHostConfiguration

    func tunnelArguments(localSocketPath: String, remoteSocketPath: String) throws -> [String] {
        try validateConfiguration()
        try validateLocalSocketPath(localSocketPath)
        try validateSocketPath(remoteSocketPath)
        var arguments = [
            "-n", "-N",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "StreamLocalBindUnlink=yes"
        ]
        appendIdentityAndPort(to: &arguments)
        arguments += ["-L", "\(localSocketPath):\(remoteSocketPath)", target]
        return arguments
    }

    func execArguments(remoteCommand: [String]) throws -> [String] {
        try validateConfiguration()
        var arguments = ["-o", "BatchMode=yes"]
        appendIdentityAndPort(to: &arguments)
        arguments += [target, try remoteCommand.map(remoteArgument).joined(separator: " ")]
        return arguments
    }

    func attachShellCommand(agent: String) throws -> String {
        try validateConfiguration()
        var parts = ["ssh", "-t"]
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

    private func validateConfiguration() throws {
        let errors = configuration.validate()
        guard errors.isEmpty else { throw LeoSSHCommandError.invalidConfiguration(errors) }
    }
}
