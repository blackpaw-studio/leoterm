import Testing

@testable import Ghostty

/// The SFTP subsystem argv must ride the tunnel's ControlMaster and never
/// open a connection of its own. Pure argv checks -- nothing runs ssh.
struct LeoSSHCommandSFTPTests {
    private let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "evan@build.example:2222", identityFile: "/keys/build"))

    @Test func buildsExactSFTPSubsystemArguments() throws {
        #expect(try command.sftpArguments(controlPath: "/tmp/cm-build") == [
            "-T", "-o", "BatchMode=yes",
            "-o", "ControlMaster=no", "-o", "ControlPath=/tmp/cm-build",
            "-o", "ProxyCommand=/usr/bin/false", "-o", "ClearAllForwardings=yes",
            "-i", "/keys/build", "-p", "2222", "-s", "evan@build.example", "sftp"
        ])
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
        #expect(sftp.suffix(2).first == tunnel.last, "same ssh target")
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
