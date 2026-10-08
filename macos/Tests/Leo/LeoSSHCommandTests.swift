import Foundation
import Testing

@testable import Ghostty

struct LeoSSHCommandTests {
    @Test func buildsExactTunnelArguments() throws {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "evan@build.example:2222", identityFile: "/keys/build"))
        #expect(try command.tunnelArguments(
            localSocketPath: "/tmp/build.sock", remoteSocketPath: "/home/evan/.leo/state/leo.sock", controlPath: "/tmp/cm-build"
        ) == [
            "-n", "-N", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=yes", "-o", "ControlPath=/tmp/cm-build", "-o", "ControlPersist=no",
            "-o", "StreamLocalBindUnlink=yes", "-i", "/keys/build", "-p", "2222", "-L",
            "/tmp/build.sock:/home/evan/.leo/state/leo.sock", "evan@build.example"
        ])
    }

    @Test func omitsIdentityAndPortWhenAbsent() throws {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build.example"))
        #expect(try command.execArguments(remoteCommand: ["printf", "%s", "hello"]) == [
            "-o", "BatchMode=yes", "build.example", "'printf' '%s' 'hello'"
        ])
    }

    @Test func shellAttachQuotesHostileValuesAtBothShellLayersAndKeepsAgentDelimiter() throws {
        let command = LeoSSHCommand(configuration: .init(
            name: "Build",
            sshTarget: "evan@build.example:2200",
            identityFile: "/keys/it' s",
            remoteLeoPath: "/opt/leo $(bad)"
        ))
        #expect(try command.remoteAttachCommand(agent: "-it's $(bad)") == "'/opt/leo $(bad)' agent attach -- '-it'\\''s $(bad)'")
        #expect(try command.attachShellCommand(agent: "-it's $(bad)") == #"env -u TMUX -u TMUX_PANE ssh -t -i '/keys/it'\'' s' -p '2200' 'evan@build.example' ''\''/opt/leo $(bad)'\'' agent attach -- '\''-it'\''\'\'''\''s $(bad)'\'''"#)
    }

    @Test func remoteAttachPlacesDispatchInBackgroundWhenAdvertised() throws {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build", remoteLeoPath: "/opt/leo"))
        let placement = LeoDaemonFeatures(["attach_dispatch_placement"])
        let remote = "'/opt/leo' agent attach --dispatch-placement background -- 'worker'"
        #expect(try command.remoteAttachCommand(agent: "worker", features: placement) == remote)
        #expect(try command.attachShellCommand(agent: "worker", features: placement)
            == "env -u TMUX -u TMUX_PANE ssh -t 'build' " + (try leoShellQuote(remote)))
        #expect(try command.remoteAttachCommand(agent: "worker", features: LeoDaemonFeatures(["dispatch_attach"]))
            == "'/opt/leo' agent attach -- 'worker'")
    }

    @Test func remoteAttachWithPlacementQuotesHostileAgentNamesAtBothShellLayers() throws {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build", remoteLeoPath: "/opt/leo"))
        let placement = LeoDaemonFeatures(["attach_dispatch_placement"])
        let agent = "--cc'; $(id) `id`\n"
        let remote = try command.remoteAttachCommand(agent: agent, features: placement)
        #expect(remote == "'/opt/leo' agent attach --dispatch-placement background -- " + #"'--cc'\''; $(id) `id`"# + "\n'")
        #expect(try command.attachShellCommand(agent: agent, features: placement)
            == "env -u TMUX -u TMUX_PANE ssh -t 'build' " + (try leoShellQuote(remote)))
    }

    @Test func hostileAgentNameArrivesAsOneInertArgvElementThroughBothShells() throws {
        let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let marker = work.appending(path: "pwned").path
        // Stands in for `ssh` (prints its argv, one per line) and for the leo binary.
        let ssh = work.appending(path: "ssh")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)

        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build", remoteLeoPath: "/opt/leo"))
        let agent = "-x'; touch \(marker); $(touch \(marker)) `touch \(marker)` \"q\" \\"
        let local = try command.attachShellCommand(agent: agent, features: LeoDaemonFeatures(["attach_dispatch_placement"]))
            .replacingOccurrences(of: "ssh -t", with: "'\(ssh.path)' -t")

        // Local shell layer runs the ssh stand-in; its single remote-command argv element
        // is then run through a second shell, as sshd would.
        let sshArgv = try Self.runShell(local).split(separator: "\0", omittingEmptySubsequences: false).dropLast()
        let remote = try #require(sshArgv.last)
        #expect(sshArgv.dropLast().map(String.init) == ["-t", "build"])
        let leo = work.appending(path: "leo")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done\n".write(to: leo, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: leo.path)
        let leoArgv = try Self.runShell(remote.replacingOccurrences(of: "'/opt/leo'", with: "'\(leo.path)'"))
            .split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)

        #expect(leoArgv == ["agent", "attach", "--dispatch-placement", "background", "--", agent])
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    private static func runShell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test func tildeLeoPathIsExpandedOnlyByTheRemoteShell() throws {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build", remoteLeoPath: "~/.local/bin/leo"))
        #expect(try command.remoteAttachCommand(agent: "name") == "~/'.local/bin/leo' agent attach -- 'name'")
        #expect(try command.attachShellCommand(agent: "name") == #"env -u TMUX -u TMUX_PANE ssh -t 'build' '~/'\''.local/bin/leo'\'' agent attach -- '\''name'\'''"#)
    }

    @Test func attachQuotesBackticksAtBothShellLayers() throws {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build"))
        #expect(try command.remoteAttachCommand(agent: "a`id`b") == "~/'.local/bin/leo' agent attach -- 'a`id`b'")
        #expect(try command.attachShellCommand(agent: "a`id`b") == #"env -u TMUX -u TMUX_PANE ssh -t 'build' '~/'\''.local/bin/leo'\'' agent attach -- '\''a`id`b'\'''"#)
    }

    @Test func attachQuotesSemicolonsNewlinesAndSubstitutionsAtBothShellLayers() throws {
        let semicolon = ";"
        let command = LeoSSHCommand(configuration: .init(
            name: "Build",
            sshTarget: "build",
            remoteLeoPath: "/opt/leo" + semicolon + "\n$(bad)"
        ))
        let agent = "agent" + semicolon + "\n$(bad)"
        let remote = "'/opt/leo" + semicolon + "\n$(bad)' agent attach -- '" + agent + "'"
        let local = "env -u TMUX -u TMUX_PANE ssh -t 'build' ''\\''/opt/leo" + semicolon + "\n$(bad)'\\'' agent attach -- '\\''" + agent + "'\\'''"
        #expect(try command.remoteAttachCommand(agent: agent) == remote)
        #expect(try command.attachShellCommand(agent: agent) == local)
    }

    @Test func logsShellCommandHasNoEnvPrefixLikeTheLocalLogsCommand() throws {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build", remoteLeoPath: "~/.local/bin/leo"))
        #expect(try command.remoteLogsCommand(agent: "name") == "~/'.local/bin/leo' agent logs -f -- 'name'")
        #expect(try command.logsShellCommand(agent: "name") == #"ssh -t 'build' '~/'\''.local/bin/leo'\'' agent logs -f -- '\''name'\'''"#)
    }

    @Test func logsShellCommandIncludesIdentityAndPort() throws {
        let command = LeoSSHCommand(configuration: .init(
            name: "Build", sshTarget: "evan@build.example:2200", identityFile: "/keys/build", remoteLeoPath: "/opt/leo"
        ))
        #expect(try command.remoteLogsCommand(agent: "agent") == "'/opt/leo' agent logs -f -- 'agent'")
        #expect(try command.logsShellCommand(agent: "agent") == #"ssh -t -i '/keys/build' -p '2200' 'evan@build.example' ''\''/opt/leo'\'' agent logs -f -- '\''agent'\'''"#)
    }

    @Test func attachRejectsNulInRemotePathOrAgent() {
        let pathWithNul = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build", remoteLeoPath: "/opt/leo\0"))
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build"))
        #expect(throws: LeoShellQuoteError.nulByte) {
            try pathWithNul.attachShellCommand(agent: "agent")
        }
        #expect(throws: LeoShellQuoteError.nulByte) {
            try command.attachShellCommand(agent: "agent\0")
        }
    }

    @Test func execQuotesRemotePathsWithShellMetacharacters() throws {
        let command = LeoSSHCommand(configuration: .init(
            name: "Build",
            sshTarget: "build",
            remoteLeoPath: "~/bin/it's $(not shell)"
        ))
        #expect(try command.execArguments(remoteCommand: [
            "~/bin/it's $(not shell)", "template", "list", "--json"
        ]) == [
            "-o", "BatchMode=yes", "build",
            "~/'bin/it'\\''s $(not shell)' 'template' 'list' '--json'"
        ])
    }

    @Test func homeCommandAndSocketResolution() throws {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "evan@build"))
        #expect(try command.remoteHomeCommand() == ["-o", "BatchMode=yes", "evan@build", "printf %s \"$HOME\""])
        #expect(try command.resolvedRemoteSocketPath(home: "/Users/evan") == "/Users/evan/.leo/state/leo.sock")
        let absolute = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build", remoteSocketPath: "/var/run/leo.sock"))
        #expect(try absolute.resolvedRemoteSocketPath(home: "/Users/evan") == "/var/run/leo.sock")
    }

    @Test(arguments: [
        ("/tmp/local:socket", "/remote/socket"),
        ("/tmp/local.socket", "/remote:socket")
    ])
    func rejectsColonInSocketPaths(_ local: String, _ remote: String) {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build"))
        #expect(throws: LeoSSHCommandError.invalidSocketPath) {
            try command.tunnelArguments(localSocketPath: local, remoteSocketPath: remote, controlPath: "/tmp/cm")
        }
    }

    @Test func rejectsLocalSocketPathsOverOneHundredUTF8Bytes() {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build"))
        #expect(throws: LeoSSHCommandError.invalidSocketPath) {
            try command.tunnelArguments(
                localSocketPath: "/tmp/" + String(repeating: "a", count: 96),
                remoteSocketPath: "/remote/socket",
                controlPath: "/tmp/cm"
            )
        }
    }

    @Test func buildersRejectInvalidConfigurations() {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "@-V"))
        let expected = LeoSSHCommandError.invalidConfiguration([.unsafeSSHTarget])
        #expect(throws: expected) { try command.tunnelArguments(localSocketPath: "/tmp/socket", remoteSocketPath: "/remote/socket", controlPath: "/tmp/cm") }
        #expect(throws: expected) { try command.execArguments(remoteCommand: ["printf"]) }
        #expect(throws: expected) { try command.sftpArguments(controlPath: "/tmp/cm") }
        #expect(throws: expected) { try command.attachShellCommand(agent: "agent") }
        #expect(throws: expected) { try command.logsShellCommand(agent: "agent") }
        #expect(throws: expected) { try command.remoteHomeCommand() }
        #expect(throws: expected) { try command.resolvedRemoteSocketPath(home: "/Users/evan") }
    }

    @Test(arguments: ["", "relative/socket"])
    func requiresAnAbsoluteResolvedRemoteSocketPath(_ remotePath: String) {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build", remoteSocketPath: remotePath))
        #expect(throws: LeoSSHCommandError.invalidSocketPath) {
            try command.resolvedRemoteSocketPath(home: "/Users/evan")
        }
    }

    @Test func expandsTildeSocketPathAndRejectsRelativeHome() throws {
        let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "build", remoteSocketPath: "~/relative/socket"))
        #expect(try command.resolvedRemoteSocketPath(home: "/Users/evan") == "/Users/evan/relative/socket")
        #expect(throws: LeoSSHCommandError.invalidSocketPath) {
            try command.resolvedRemoteSocketPath(home: "relative")
        }
    }
}
