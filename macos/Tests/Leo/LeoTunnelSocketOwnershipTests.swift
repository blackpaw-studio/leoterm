import Darwin
import Foundation
import Testing

@testable import Ghostty

/// One tunnel per host (D-049): a tunnel socket path belongs to whichever
/// running copy of the app holds an exclusive `flock` on `<path>.lock`.
/// A held lock is a live sibling -- an error the user sees, never unlinked
/// or rebound however its socket looks. A free lock means nobody live owns
/// the path, so whatever socket is there is removed without a probe.
@Suite(.serialized)
struct LeoTunnelSocketOwnershipTests {
    /// A sibling's socket can answer `connect` with ECONNREFUSED (a full
    /// backlog on Darwin) and look dead: the lock, not a probe, decides.
    @Test func aLockedPathIsInUseEvenWhenItsSocketLooksDead() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { Self.cleanUp(path) }
        try LeoTestUnixSocket.leaveStale(path)
        let sibling = try #require(LeoTestFileLock.hold(path + ".lock"))
        defer { close(sibling) }
        let tunnel = try Self.makeTunnel(path)
        defer { tunnel.terminateAndWait() }

        await #expect(throws: LeoTunnelError.socketInUse(path: path)) { try await tunnel.start() }

        #expect(tunnel.pid == nil)
        #expect(LeoControlSocket.inspect(path) == .stale)
    }

    @Test func aSecondTunnelForTheSamePathFailsAndLeavesTheFirstRunning() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { Self.cleanUp(path) }
        let first = try Self.makeTunnel(path)
        defer { first.terminateAndWait() }
        try await first.start()
        let second = try Self.makeTunnel(path)
        defer { second.terminateAndWait() }

        await #expect(throws: LeoTunnelError.socketInUse(path: path)) { try await second.start() }

        #expect(second.pid == nil)
        #expect(!first.hasExited)
        #expect(LeoControlSocket.inspect(path) == .live)
    }

    /// Nobody holds the lock, so the socket is an orphaned forward from a
    /// run that's gone -- even if its ssh still listens -- and is replaced.
    @Test func anUnlockedSocketIsRemovedWithoutProbingIt() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { Self.cleanUp(path) }
        let orphan = try LeoTestUnixSocket.bind(path, listening: true)
        defer { close(orphan) }
        let tunnel = try Self.makeTunnel(path)
        defer { tunnel.terminateAndWait() }

        try await tunnel.start()

        #expect(try await LeoTunnelTestSupport.healthProbe(path))
    }

    @Test func aDeadSocketIsRemovedAndTheTunnelStarts() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { Self.cleanUp(path) }
        try LeoTestUnixSocket.leaveStale(path)
        let tunnel = try Self.makeTunnel(path)
        defer { tunnel.terminateAndWait() }

        try await tunnel.start()

        #expect(LeoControlSocket.inspect(path) == .live)
    }

    @Test func theLockIsHeldWhileTheTunnelRunsAndReleasedWhenItStops() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { Self.cleanUp(path) }
        let tunnel = try Self.makeTunnel(path)
        defer { tunnel.terminateAndWait() }
        try await tunnel.start()

        #expect(LeoTestFileLock.hold(path + ".lock") == nil)
        tunnel.terminateAndWait()

        let after = try #require(LeoTestFileLock.hold(path + ".lock"))
        close(after)
    }

    @Test func theLockIsReleasedWhenSSHDiesOnItsOwn() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { Self.cleanUp(path) }
        let tunnel = try Self.makeTunnel(path)
        defer { tunnel.terminateAndWait() }
        try await tunnel.start()

        _ = Darwin.kill(try #require(tunnel.pid), SIGKILL)

        await awaitCondition(message: "the lock outlived ssh") {
            guard let descriptor = LeoTestFileLock.hold(path + ".lock") else { return false }
            close(descriptor)
            return true
        }
    }

    /// Held in the app, never by ssh: a child that inherited it would keep
    /// the path "in use" after the app itself let go.
    @Test func aChildProcessNeverInheritsTheLock() throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { Self.cleanUp(path) }
        let lock = try LeoTunnelSocketLock.acquire(for: path)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }

        lock.release()

        let descriptor = try #require(LeoTestFileLock.hold(path + ".lock"))
        close(descriptor)
    }

    @Test func aSymlinkedLockFileIsRefused() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        let target = path + ".target"
        defer { Self.cleanUp(path); unlink(target) }
        FileManager.default.createFile(atPath: target, contents: Data())
        #expect(symlink(target, path + ".lock") == 0)
        let tunnel = try Self.makeTunnel(path)

        await #expect(throws: LeoTunnelError.self) { try await tunnel.start() }

        #expect(tunnel.pid == nil)
    }

    /// An existing lock file of ours with a looser mode is tightened.
    @Test func aLooseLockFileIsTightenedToOwnerOnly() throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { Self.cleanUp(path) }
        FileManager.default.createFile(atPath: path + ".lock", contents: Data(), attributes: [.posixPermissions: 0o644])

        let lock = try LeoTunnelSocketLock.acquire(for: path)
        defer { lock.release() }

        var info = Darwin.stat()
        #expect(lstat(path + ".lock", &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    /// A hard link could make the lock file an alias of a file elsewhere.
    @Test func aHardLinkedLockFileIsRefused() throws {
        let path = LeoTunnelTestSupport.socketPath()
        let other = path + ".other"
        defer { Self.cleanUp(path); unlink(other) }
        FileManager.default.createFile(atPath: other, contents: Data(), attributes: [.posixPermissions: 0o600])
        #expect(link(other, path + ".lock") == 0)

        #expect(throws: LeoTunnelSocketLockError.self) { _ = try LeoTunnelSocketLock.acquire(for: path) }
    }

    @Test func aFileAtTheSocketPathIsLeftAndTheTunnelFails() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { Self.cleanUp(path) }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        let tunnel = try Self.makeTunnel(path)
        defer { tunnel.terminateAndWait() }

        await #expect(throws: LeoTunnelError.self) { try await tunnel.start() }

        #expect(tunnel.pid == nil)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
    }

    @Test func anotherUsersSocketIsLeftAndTheTunnelFails() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        defer { Self.cleanUp(path) }
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

    private static func cleanUp(_ path: String) {
        unlink(path)
        unlink(path + ".lock")
    }
}

/// Stands in for another running copy of the app: an exclusive `flock`
/// on its own open of the file, which conflicts with any other open --
/// even one in this same process.
enum LeoTestFileLock {
    /// The descriptor holding the lock, or nil if someone else holds it.
    static func hold(_ path: String) -> Int32? {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }
}
