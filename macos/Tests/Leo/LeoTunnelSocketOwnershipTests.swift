import Darwin
import Foundation
import Testing

@testable import Ghostty

/// One tunnel per host: `LeoTunnel` only ever clears a socket nobody is
/// listening on. A live sibling (another copy of the app forwarding the same
/// host) is an error the user sees, never something to unlink and rebind.
@Suite(.serialized)
struct LeoTunnelSocketOwnershipTests {
    @Test func aLiveSiblingSocketSurvivesAndTheTunnelFailsWithoutLaunching() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { unlink(path) }
        let listener = try LeoTestUnixSocket.bind(path, listening: true)
        defer { close(listener) }
        let tunnel = try Self.makeTunnel(path)
        defer { tunnel.terminateAndWait() }

        await #expect(throws: LeoTunnelError.socketInUse(path: path)) { try await tunnel.start() }

        #expect(tunnel.pid == nil)
        #expect(LeoControlSocket.inspect(path) == .live)
    }

    /// An orphaned forward from a crashed run recovers without user action.
    @Test func aDeadSocketIsRemovedAndTheTunnelStarts() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { unlink(path) }
        try LeoTestUnixSocket.leaveStale(path)
        let tunnel = try Self.makeTunnel(path)
        defer { tunnel.terminateAndWait() }

        try await tunnel.start()

        #expect(LeoControlSocket.inspect(path) == .live)
    }

    @Test func aFileAtTheSocketPathIsLeftAndTheTunnelFails() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { unlink(path) }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        let tunnel = try Self.makeTunnel(path)
        defer { tunnel.terminateAndWait() }

        await #expect(throws: LeoTunnelError.self) { try await tunnel.start() }

        #expect(tunnel.pid == nil)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
    }

    @Test func anotherUsersSocketIsLeftAndTheTunnelFails() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { unlink(path) }
        try LeoTestUnixSocket.leaveStale(path)
        let tunnel = try Self.makeTunnel(path, owner: geteuid() + 1)
        defer { tunnel.terminateAndWait() }

        await #expect(throws: LeoTunnelError.self) { try await tunnel.start() }

        #expect(tunnel.pid == nil)
        #expect(LeoControlSocket.inspect(path) == .stale)
    }

    private static func makeTunnel(_ path: String, owner: uid_t = geteuid()) throws -> LeoTunnel {
        LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            socketOwner: owner,
            healthProbe: LeoTunnelTestSupport.healthProbe
        )
    }
}
