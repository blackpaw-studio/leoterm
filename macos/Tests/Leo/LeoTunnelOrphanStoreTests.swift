import Darwin
import Foundation
import Testing

@testable import Ghostty

struct LeoTunnelOrphanStoreTests {
    @Test func matchingPidIsSignalledAndSocketAndRecordAreCleared() throws {
        let defaults = try freshDefaults()
        let path = LeoTunnelTestSupport.socketPath()
        try LeoTestUnixSocket.leaveStale(path)
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        store.record(LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: path))
        var signals: [Int32] = []
        var alive = true

        store.reapAtLaunch(
            inspector: { _ in alive ? 99 : nil },
            signaller: { _, signal in signals.append(signal); alive = false },
            sleep: { _ in }
        )

        #expect(signals == [SIGTERM])
        #expect(store.current() == nil)
        #expect(LeoControlSocket.inspect(path) == .absent)
    }

    @Test func stillAliveAfterSigtermEscalatesToSigkill() throws {
        let defaults = try freshDefaults()
        let path = LeoTunnelTestSupport.socketPath()
        try LeoTestUnixSocket.leaveStale(path)
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        store.record(LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: path))
        var signals: [Int32] = []

        store.reapAtLaunch(
            inspector: { _ in 99 },
            signaller: { _, signal in signals.append(signal) },
            sleep: { _ in }
        )

        #expect(signals == [SIGTERM, SIGKILL])
        #expect(store.current() == nil)
        #expect(LeoControlSocket.inspect(path) == .absent)
    }

    @Test func mismatchedStartTimeIsNeverSignalledAndRecordIsUntouched() throws {
        let defaults = try freshDefaults()
        let path = LeoTunnelTestSupport.socketPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        let record = LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: path)
        store.record(record)
        var signals: [Int32] = []

        store.reapAtLaunch(
            inspector: { _ in 100 },
            signaller: { _, signal in signals.append(signal) },
            sleep: { _ in }
        )

        #expect(signals.isEmpty)
        #expect(store.current() == record)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func replacementRecordWrittenDuringReapIsPreservedAndItsSocketIsUntouched() throws {
        let defaults = try freshDefaults()
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        let original = LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: LeoTunnelTestSupport.socketPath())
        let replacement = LeoTunnelOrphanRecord(pid: 43, startTime: 100, socketPath: LeoTunnelTestSupport.socketPath())
        FileManager.default.createFile(atPath: replacement.socketPath, contents: Data())
        store.record(original)
        var alive = true

        store.reapAtLaunch(
            inspector: { _ in alive ? 99 : nil },
            signaller: { _, _ in
                // Simulate a new tunnel recording its own orphan while this reap
                // is still in flight (e.g. SIGTERM delivery racing a fresh launch).
                store.record(replacement)
                alive = false
            },
            sleep: { _ in }
        )

        #expect(store.current() == replacement)
        #expect(FileManager.default.fileExists(atPath: replacement.socketPath))
    }

    /// A crash leaves a record whose ssh already died (e.g. after a reboot):
    /// nothing to signal, but its dead socket is still cleaned up.
    @Test func aRecordWhoseProcessIsGoneHasItsDeadSocketRemovedAndIsCleared() throws {
        let defaults = try freshDefaults()
        let path = LeoTunnelTestSupport.socketPath()
        try LeoTestUnixSocket.leaveStale(path)
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        store.record(LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: path))
        var signals: [Int32] = []

        store.reapAtLaunch(inspector: { _ in nil }, signaller: { _, signal in signals.append(signal) }, sleep: { _ in })

        #expect(signals.isEmpty)
        #expect(store.current() == nil)
        #expect(LeoControlSocket.inspect(path) == .absent)
    }

    /// Records saved before B-021 point into `~/.leo/state/leoterm/`: the
    /// dead socket this app left there goes, nothing else in it is touched.
    @Test func aPreB021RecordRemovesOnlyItsOwnDeadSocketFromTheOldDirectory() throws {
        let (root, legacy) = try Self.makeLegacyDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = LeoHostConfiguration(name: "work", sshTarget: "evan@work")
        let recorded = legacy.appendingPathComponent(host.legacySocketFileName).path
        let otherStale = legacy.appendingPathComponent("other-000000000000.sock").path
        let live = legacy.appendingPathComponent("live-000000000000.sock").path
        let file = legacy.appendingPathComponent("notes.txt").path
        try LeoTestUnixSocket.leaveStale(recorded)
        try LeoTestUnixSocket.leaveStale(otherStale)
        let listener = try LeoTestUnixSocket.bind(live, listening: true)
        defer { close(listener) }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: file))
        let store = LeoTunnelOrphanStore(defaults: try freshDefaults(), key: "orphan")
        store.record(LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: recorded))
        var alive = true

        store.reapAtLaunch(inspector: { _ in alive ? 99 : nil }, signaller: { _, _ in alive = false }, sleep: { _ in })

        #expect(LeoControlSocket.inspect(recorded) == .absent)
        #expect(LeoControlSocket.inspect(otherStale) == .stale)
        #expect(LeoControlSocket.inspect(live) == .live)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "keep")
        #expect(store.current() == nil)
    }

    /// Another running copy holds the recorded path's lock: the record is
    /// its tunnel's, not an orphan. Nothing is signalled or removed.
    @Test func aRecordWhosePathIsLockedIsNeverReaped() throws {
        let defaults = try freshDefaults()
        let path = LeoTunnelTestSupport.socketPath()
        defer { unlink(path); unlink(path + ".lock") }
        try LeoTestUnixSocket.leaveStale(path)
        let sibling = try #require(LeoTestFileLock.hold(path + ".lock"))
        defer { close(sibling) }
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        let record = LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: path)
        store.record(record)
        var signals: [Int32] = []

        store.reapAtLaunch(inspector: { _ in 99 }, signaller: { _, signal in signals.append(signal) }, sleep: { _ in })

        #expect(signals.isEmpty)
        #expect(store.current() == record)
        #expect(LeoControlSocket.inspect(path) == .stale)
    }

    /// With the lock free nobody live owns the path, so the dead app's
    /// socket goes without a probe -- even one its orphaned ssh still
    /// listens on. A file or another user's socket there stays.
    @Test func withTheLockFreeOnlyThisUsersSocketAtTheRecordedPathIsRemoved() throws {
        let (root, legacy) = try Self.makeLegacyDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let listening = legacy.appendingPathComponent("live.sock").path
        let file = legacy.appendingPathComponent("file.sock").path
        let foreign = legacy.appendingPathComponent("foreign.sock").path
        let listener = try LeoTestUnixSocket.bind(listening, listening: true)
        defer { close(listener) }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: file))
        try LeoTestUnixSocket.leaveStale(foreign)
        let cases: [(path: String, owner: uid_t)] = [(listening, geteuid()), (file, geteuid()), (foreign, geteuid() + 1)]

        for (path, owner) in cases {
            let store = LeoTunnelOrphanStore(defaults: try freshDefaults(), key: "orphan", socketOwner: owner)
            store.record(LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: path))
            var alive = true
            store.reapAtLaunch(inspector: { _ in alive ? 99 : nil }, signaller: { _, _ in alive = false }, sleep: { _ in })
        }

        #expect(LeoControlSocket.inspect(listening) == .absent)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "keep")
        #expect(LeoControlSocket.inspect(foreign) == .stale)
    }

    /// The pid is re-checked right before every signal, the SIGKILL
    /// escalation included: a pid recycled in between is never signalled.
    @Test func aPidRecycledBeforeTheEscalationIsNeverKilled() throws {
        let defaults = try freshDefaults()
        let path = LeoTunnelTestSupport.socketPath()
        defer { unlink(path); unlink(path + ".lock") }
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        store.record(LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: path))
        var signals: [Int32] = []
        var startTime: TimeInterval = 99

        store.reapAtLaunch(
            inspector: { _ in startTime },
            signaller: { _, signal in signals.append(signal) },
            sleep: { _ in startTime = 100 }
        )

        #expect(signals == [SIGTERM])
    }

    /// A stand-in home's `.leo/state/leoterm/`, never the real one.
    private static func makeLegacyDirectory() throws -> (root: URL, legacy: URL) {
        let root = LeoHostSelectionTestSupport.makeIsolatedSocketDirectory()
        let legacy = root.appendingPathComponent(".leo/state/leoterm", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (root, legacy)
    }

    private func freshDefaults() throws -> UserDefaults {
        let suite = "LeoTunnelOrphanStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileNoSuchFile) }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
