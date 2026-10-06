import Testing

@testable import Ghostty

/// The SFTP server argv must ride the tunnel's ControlMaster and never
/// open a connection of its own. Pure argv checks -- nothing runs ssh.
struct LeoSSHCommandSFTPTests {
    private let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "evan@build.example:2222", identityFile: "/keys/build"))

    @Test func buildsExactSFTPBootstrapArguments() throws {
        #expect(try command.sftpArguments(controlPath: "/tmp/cm-build") == [
            "-T", "-o", "BatchMode=yes",
            "-o", "ControlMaster=no", "-o", "ControlPath=/tmp/cm-build",
            "-o", "ProxyCommand=/usr/bin/false", "-o", "ClearAllForwardings=yes",
            "-o", "RemoteCommand=none", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no",
            "-i", "/keys/build", "-p", "2222", "evan@build.example", LeoSSHCommand.sftpServerBootstrapCommand
        ])
    }

    /// The overrides OpenSSH's own `sftp(1)` passes: a user config's
    /// RemoteCommand would replace the subsystem, agent/X11 forwarding would
    /// hand the remote side credentials it never needs, a LocalCommand would
    /// run on every session, and the tunnel's forwards must not be
    /// re-requested per session.
    @Test func sftpOverridesUserConfigLikeOpenSSHsSFTPClient() throws {
        let sftp = try command.sftpArguments(controlPath: "/tmp/cm-build")
        #expect(Self.option("RemoteCommand", in: sftp) == "none")
        #expect(Self.option("ForwardAgent", in: sftp) == "no")
        #expect(Self.option("ForwardX11", in: sftp) == "no")
        #expect(Self.option("PermitLocalCommand", in: sftp) == "no")
        #expect(Self.option("ClearAllForwardings", in: sftp) == "yes")
        let target = try #require(sftp.firstIndex(of: "evan@build.example"))
        let lastOverride = try #require(sftp.firstIndex(of: "PermitLocalCommand=no"))
        #expect(lastOverride < target, "options precede the target")
    }

    /// A control path ssh can't use (spaces, non-ASCII, too long) must not
    /// cost the user the tunnel: it runs without a master instead.
    @Test func aTunnelWithoutAControlPathDoesNotMultiplex() throws {
        let tunnel = try command.tunnelArguments(localSocketPath: "/tmp/b.sock", remoteSocketPath: "/r/leo.sock", controlPath: nil)
        #expect(tunnel == [
            "-n", "-N", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "StreamLocalBindUnlink=yes", "-i", "/keys/build", "-p", "2222", "-L",
            "/tmp/b.sock:/r/leo.sock", "evan@build.example"
        ])
    }

    @Test(arguments: [
        ("/tmp/cm-build", true), ("/Users/Evan Coleman/.leo/state/leoterm/cm", false), ("/Users/évan/cm", false),
        ("/tmp/percent%h", false), ("relative/cm", false), ("/tmp/" + String(repeating: "a", count: 82), false)
    ])
    func classifiesControlPaths(_ path: String, _ isValid: Bool) {
        #expect(LeoSSHCommand.isValidControlPath(path) == isValid)
    }

    @Test func sftpReusesTheTunnelsControlPathIdentityPortAndTarget() throws {
        let tunnel = try command.tunnelArguments(localSocketPath: "/tmp/b.sock", remoteSocketPath: "/r/leo.sock", controlPath: "/tmp/cm-build")
        let sftp = try command.sftpArguments(controlPath: "/tmp/cm-build")

        #expect(Self.option("ControlPath", in: tunnel) == "/tmp/cm-build")
        #expect(Self.option("ControlPath", in: sftp) == Self.option("ControlPath", in: tunnel))
        #expect(Self.option("ControlMaster", in: tunnel) == "yes", "the tunnel process is the master")
        #expect(Self.option("ControlMaster", in: sftp) == "no", "SFTP is only ever a mux client")
        #expect(Self.value(after: "-i", in: sftp) == Self.value(after: "-i", in: tunnel))
        #expect(Self.value(after: "-p", in: sftp) == Self.value(after: "-p", in: tunnel))
        #expect(sftp.dropLast().last == tunnel.last, "same ssh target")
        #expect(sftp.last == LeoSSHCommand.sftpServerBootstrapCommand)
    }

    @Test func sftpUsesOnlyAFixedServerBootstrap() throws {
        let sftp = try command.sftpArguments(controlPath: "/tmp/cm-build")
        let bootstrap = try #require(sftp.last)

        #expect(!sftp.contains("-s"), "file access does not depend on an sshd subsystem entry")
        #expect(bootstrap == LeoSSHCommand.sftpServerBootstrapCommand)
        #expect(bootstrap.contains(LeoSSHCommand.missingSFTPServerMarker))
        #expect(!bootstrap.contains("build.example"))
        #expect(!bootstrap.contains("/keys/build"))
        #expect(!bootstrap.contains("/tmp/cm-build"))
    }

    /// If the master is gone, ssh would silently dial a fresh connection;
    /// `ProxyCommand=/usr/bin/false` makes that fallback fail instead
    /// (ssh tries the ControlPath before the proxy), and BatchMode rules out
    /// any password prompt either way.
    @Test func sftpCannotFallBackToADirectOrInteractiveConnection() throws {
        let sftp = try command.sftpArguments(controlPath: "/tmp/cm-build")
        #expect(Self.option("ProxyCommand", in: sftp) == "/usr/bin/false")
        #expect(Self.option("BatchMode", in: sftp) == "yes")
        #expect(sftp.first == "-T", "a pty would corrupt the binary protocol")
        #expect(!sftp.contains("-t"))
    }

    @Test func theTunnelKeepsItsMultiplexerInTheForeground() throws {
        let tunnel = try command.tunnelArguments(localSocketPath: "/tmp/b.sock", remoteSocketPath: "/r/leo.sock", controlPath: "/tmp/cm-build")
        #expect(Self.option("ControlPersist", in: tunnel) == "no", "a persisting master would fork away from LeoTunnel's pid")
    }

    @Test(arguments: [
        "relative/cm", "", "/tmp/with space/cm", "/tmp/percent%h", "/tmp/quote\"cm", "/tmp/" + String(repeating: "a", count: 82)
    ])
    func rejectsControlPathsSSHWouldMisparseOrCannotBind(_ path: String) {
        #expect(throws: LeoSSHCommandError.invalidControlPath) { try command.sftpArguments(controlPath: path) }
        #expect(throws: LeoSSHCommandError.invalidControlPath) {
            try command.tunnelArguments(localSocketPath: "/tmp/b.sock", remoteSocketPath: "/r/leo.sock", controlPath: path)
        }
    }

    @Test func acceptsTheLongestBindableControlPath() throws {
        let path = "/tmp/" + String(repeating: "a", count: 81)
        #expect(path.utf8.count == 86)
        #expect(Self.option("ControlPath", in: try command.sftpArguments(controlPath: path)) == path)
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        arguments.lazy.compactMap { argument -> String? in
            guard argument.hasPrefix(name + "=") else { return nil }
            return String(argument.dropFirst(name.count + 1))
        }.first
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
