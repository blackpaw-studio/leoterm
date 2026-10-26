import Testing

@testable import Ghostty
@testable import LeoKit

/// Pure argv checks for the port-forward commands; nothing runs ssh.
struct LeoSSHCommandForwardTests {
    private let command = LeoSSHCommand(configuration: .init(name: "Build", sshTarget: "evan@build.example:2222", identityFile: "/keys/build"))

    @Test func buildsExactMuxForwardArguments() throws {
        #expect(try command.forwardArguments(controlPath: "/tmp/cm-build", local: 5173, remotePort: 5173, op: .forward, address: .ipv4) == [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no", "-o", "ControlPath=/tmp/cm-build",
            "-o", "ProxyCommand=/usr/bin/false",
            "-o", "RemoteCommand=none", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no",
            "-i", "/keys/build", "-p", "2222",
            "-O", "forward", "-L", "127.0.0.1:5173:localhost:5173", "evan@build.example"
        ])
    }

    @Test func cancelDiffersOnlyInTheControlOperation() throws {
        let forward = try command.forwardArguments(controlPath: "/tmp/cm-build", local: 49_200, remotePort: 5173, op: .forward, address: .ipv4)
        let cancel = try command.forwardArguments(controlPath: "/tmp/cm-build", local: 49_200, remotePort: 5173, op: .cancel, address: .ipv4)
        #expect(forward.map { $0 == "forward" ? "cancel" : $0 } == cancel)
        #expect(cancel.contains("127.0.0.1:49200:localhost:5173"))
    }

    /// `ClearAllForwardings=yes` would clear the `-L` the mux client is
    /// asking for, so the SFTP client's override must not be reused here.
    @Test func theMuxClientDoesNotClearItsOwnForward() throws {
        let forward = try command.forwardArguments(controlPath: "/tmp/cm-build", local: 5173, remotePort: 5173, op: .forward, address: .ipv4)
        #expect(!forward.contains { $0.contains("ClearAllForwardings") })
        #expect(forward.contains("ProxyCommand=/usr/bin/false"), "a dead master must fail fast, not dial a new connection")
    }

    @Test func theForwardBindsLoopbackOnly() throws {
        let forward = try command.forwardArguments(controlPath: "/tmp/cm-build", local: 5173, remotePort: 80, op: .forward, address: .ipv4)
        let spec = try #require(forward.firstIndex(of: "-L").map { forward[$0 + 1] })
        #expect(spec.hasPrefix("127.0.0.1:"))
    }

    @Test func theIPv6ForwardBindsTheIPv6LoopbackOnly() throws {
        let forward = try command.forwardArguments(controlPath: "/tmp/cm-build", local: 5173, remotePort: 80, op: .forward, address: .ipv6)
        #expect(forward.suffix(5) == ["-O", "forward", "-L", "[::1]:5173:localhost:80", "evan@build.example"])
    }

    @Test func theProcessFallbackListensOnBothLoopbacksInOneProcess() throws {
        let arguments = try command.forwardProcessArguments(local: 49_200, remotePort: 5173, addresses: [.ipv4, .ipv6])
        #expect(arguments.suffix(5) == ["-L", "127.0.0.1:49200:localhost:5173", "-L", "[::1]:49200:localhost:5173", "evan@build.example"])
    }

    @Test func noForwardEverBindsAnythingButLoopback() throws {
        let process = try command.forwardProcessArguments(local: 49_200, remotePort: 5173, addresses: [.ipv4, .ipv6])
        let mux = try [LeoLoopbackAddress.ipv4, .ipv6].flatMap {
            try command.forwardArguments(controlPath: "/tmp/cm-build", local: 49_200, remotePort: 5173, op: .forward, address: $0)
        }
        for arguments in [process, mux] {
            let specs = arguments.indices.filter { arguments[$0] == "-L" }.map { arguments[$0 + 1] }
            #expect(!specs.isEmpty)
            #expect(specs.allSatisfy { $0.hasPrefix("127.0.0.1:") || $0.hasPrefix("[::1]:") })
        }
    }

    @Test func buildsExactProcessFallbackArguments() throws {
        #expect(try command.forwardProcessArguments(local: 49_200, remotePort: 5173, addresses: [.ipv4]) == [
            "-n", "-N",
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-i", "/keys/build", "-p", "2222",
            "-L", "127.0.0.1:49200:localhost:5173", "evan@build.example"
        ])
    }

    @Test(arguments: [0, -1, 65_536, 100_000])
    func rejectsPortsOutsideTheValidRange(_ port: Int) {
        #expect(throws: LeoSSHCommandError.invalidPort) {
            try command.forwardArguments(controlPath: "/tmp/cm-build", local: port, remotePort: 5173, op: .forward, address: .ipv4)
        }
        #expect(throws: LeoSSHCommandError.invalidPort) {
            try command.forwardArguments(controlPath: "/tmp/cm-build", local: 5173, remotePort: port, op: .cancel, address: .ipv4)
        }
        #expect(throws: LeoSSHCommandError.invalidPort) {
            try command.forwardProcessArguments(local: port, remotePort: 5173, addresses: [.ipv4, .ipv6])
        }
        #expect(throws: LeoSSHCommandError.invalidPort) {
            try command.forwardProcessArguments(local: 5173, remotePort: port, addresses: [.ipv4, .ipv6])
        }
    }

    @Test func acceptsTheBoundaryPorts() throws {
        _ = try command.forwardArguments(controlPath: "/tmp/cm-build", local: 1, remotePort: 65_535, op: .forward, address: .ipv4)
    }

    @Test func aControlPathSSHCannotUseIsRejected() {
        #expect(throws: LeoSSHCommandError.invalidControlPath) {
            try command.forwardArguments(controlPath: "/tmp/has space", local: 5173, remotePort: 5173, op: .forward, address: .ipv4)
        }
    }
}
