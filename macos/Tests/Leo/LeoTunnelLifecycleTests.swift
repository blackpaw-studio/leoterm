import Darwin
import Foundation
import Testing

@testable import Ghostty

@Suite(.serialized)
struct LeoTunnelLifecycleTests {
    @Test func onExitFiresOnceOffMainAfterPostReadyDeath() async throws {
        let exits = ExitRecorder()
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: LeoTunnelTestSupport.healthProbe
        )
        tunnel.onExit = { exit in exits.append(exit, wasMainThread: Thread.isMainThread) }
        defer { tunnel.terminateAndWait() }

        try await tunnel.start()
        let pid = try #require(tunnel.pid)
        _ = Darwin.kill(pid, SIGKILL)

        await awaitCondition { exits.count == 1 }
        #expect(exits.count == 1)
        #expect(exits.first?.wasMainThread == false)
    }

    @Test func deliversOneExitAndCapsStderrTailAtFourKilobytes() async throws {
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_BYTES", "5000")
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_BYTES", nil) }
        let exits = ExitRecorder()
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: LeoTunnelTestSupport.healthProbe
        )
        tunnel.onExit = { exit in exits.append(exit, wasMainThread: Thread.isMainThread) }
        defer { tunnel.terminateAndWait() }
        try await tunnel.start()
        tunnel.terminateAndWait()

        await awaitCondition { exits.count == 1 }
        #expect(exits.first?.exit.stderrTail.utf8.count == 4096)
        #expect(exits.count == 1)
    }

    @Test func terminateAndWaitIsIdempotentAndKillsATermIgnoringChild() async throws {
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_IGNORE_TERM", "1")
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_IGNORE_TERM", nil) }
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: LeoTunnelTestSupport.healthProbe
        )
        defer { tunnel.terminateAndWait() }
        try await tunnel.start()
        let pid = try #require(tunnel.pid)

        tunnel.terminateAndWait()
        tunnel.terminateAndWait()

        await awaitCondition { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
    }

    @Test func terminateAndWaitCalledFromInsideOnExitReturns() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: LeoTunnelTestSupport.healthProbe
        )
        defer { tunnel.terminateAndWait() }
        let done = LeoTestFlag()
        tunnel.onExit = { [weak tunnel] _ in
            tunnel?.terminateAndWait()
            done.set()
        }
        try await tunnel.start()
        let pid = try #require(tunnel.pid)
        _ = Darwin.kill(pid, SIGKILL)

        await awaitCondition { done.isSet }
    }

    @Test func processStartTimeIsCachedAndStableAcrossReadsAndAfterExit() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: LeoTunnelTestSupport.healthProbe
        )
        defer { tunnel.terminateAndWait() }
        try await tunnel.start()
        let first = try #require(tunnel.processStartTime)
        let second = try #require(tunnel.processStartTime)
        tunnel.terminateAndWait()
        let third = try #require(tunnel.processStartTime)

        #expect(first == second)
        #expect(second == third)
    }
}

private final class ExitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(exit: LeoTunnelExit, wasMainThread: Bool)] = []
    var count: Int { lock.withLock { values.count } }
    var first: (exit: LeoTunnelExit, wasMainThread: Bool)? { lock.withLock { values.first } }
    func append(_ exit: LeoTunnelExit, wasMainThread: Bool) {
        lock.withLock { values.append((exit, wasMainThread)) }
    }
}

private final class LeoTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
