import Darwin
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoTunnelOrphanStoreTests {
    @Test func matchingPidIsSignalledAndSocketAndRecordAreCleared() throws {
        let defaults = freshDefaults()
        let path = LeoTunnelTestSupport.socketPath()
        FileManager.default.createFile(atPath: path, contents: Data())
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
        #expect(store.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func stillAliveAfterSigtermEscalatesToSigkill() throws {
        let defaults = freshDefaults()
        let path = LeoTunnelTestSupport.socketPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        store.record(LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: path))
        var signals: [Int32] = []

        store.reapAtLaunch(
            inspector: { _ in 99 },
            signaller: { _, signal in signals.append(signal) },
            sleep: { _ in }
        )

        #expect(signals == [SIGTERM, SIGKILL])
        #expect(store.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func mismatchedStartTimeIsNeverSignalledAndRecordIsUntouched() throws {
        let defaults = freshDefaults()
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
        #expect(store.records() == [record])
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func replacementRecordWrittenDuringReapIsPreservedAndItsSocketIsUntouched() throws {
        let defaults = freshDefaults()
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

        #expect(store.records() == [replacement])
        #expect(FileManager.default.fileExists(atPath: replacement.socketPath))
    }

    /// A pre-B-021 record points into `~/.leo/state/leoterm/`. The build that
    /// wrote it took no instance lock, so it may still be running beside this
    /// one: its pid is never signalled, the record is dropped, and its socket
    /// goes only if nothing listens on it.
    @Test func legacyRecordIsNeverSignalledAndItsStaleSocketAndRecordAreCleared() throws {
        let defaults = freshDefaults()
        let legacy = try LeoTestSocketDirectory()
        defer { legacy.remove() }
        let path = legacy.path("hosts-work.sock")
        try LeoTestUnixSocket.leaveStale(path)
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan", legacySocketDirectory: legacy.url)
        store.record(LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: path))
        var signals: [Int32] = []

        store.reapAtLaunch(
            inspector: { _ in 99 },
            signaller: { _, signal in signals.append(signal) },
            sleep: { _ in }
        )

        #expect(signals.isEmpty)
        #expect(store.records().isEmpty)
        #expect(LeoControlSocket.inspect(path) == .absent)
    }

    @Test func legacyRecordLeavesALiveSocketAlone() throws {
        let defaults = freshDefaults()
        let legacy = try LeoTestSocketDirectory()
        defer { legacy.remove() }
        let path = legacy.path("hosts-work.sock")
        let listener = try LeoTestUnixSocket.bind(path, listening: true)
        defer { close(listener) }
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan", legacySocketDirectory: legacy.url)
        store.record(LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: path))
        var signals: [Int32] = []

        store.reapAtLaunch(
            inspector: { _ in nil },
            signaller: { _, signal in signals.append(signal) },
            sleep: { _ in }
        )

        #expect(signals.isEmpty)
        #expect(store.records().isEmpty)
        #expect(LeoControlSocket.inspect(path) == .live)
    }

    /// Quit deadlocked: the exit-handler's `clear` held the store lock while
    /// `UserDefaults` posted a notification whose main-queue observer waited on
    /// the main thread, and `shutdown()` on main was waiting for that lock.
    @Test func clearOnMainDoesNotWaitForABackgroundClearBlockedOnMain() {
        let defaults = LeoInMemoryDefaults(postsChangeNotifications: true)
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        let record = LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: "/tmp/x.sock")
        store.record(record)
        let backgroundInWrite = DispatchSemaphore(value: 0)
        let mainReached = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        // Stands in for an observer that makes the poster wait on the main thread.
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in
            guard !Thread.isMainThread else { return }
            backgroundInWrite.signal()
            _ = mainReached.wait(timeout: .now() + 2)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        DispatchQueue.global().async {
            store.clear(matching: record)
            finished.signal()
        }
        #expect(backgroundInWrite.wait(timeout: .now() + 2) == .success)
        let start = Date()
        store.clear(matching: record)
        let mainWaited = Date().timeIntervalSince(start)
        mainReached.signal()

        #expect(mainWaited < 1)
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(store.records().isEmpty)
        #expect(defaults.data(forKey: "orphan") == nil)
    }

    @Test func recordRacingAClearNeverLosesTheNewRecord() {
        let defaults = LeoInMemoryDefaults()
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        let old = LeoTunnelOrphanRecord(pid: 1, startTime: 1, socketPath: "/tmp/old.sock")
        let new = LeoTunnelOrphanRecord(pid: 2, startTime: 2, socketPath: "/tmp/new.sock")

        for _ in 0..<200 {
            store.record(old)
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                index == 0 ? store.clear(matching: old) : store.record(new)
            }
            #expect(store.records() == [new])
            #expect(defaults.data(forKey: "orphan").flatMap { try? JSONDecoder().decode([LeoTunnelOrphanRecord].self, from: $0) } == [new])
        }
    }

    @Test func recordsForDifferentSocketsCoexistAndClearingOneKeepsTheOther() {
        let defaults = LeoInMemoryDefaults()
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        let first = LeoTunnelOrphanRecord(pid: 1, startTime: 1, socketPath: "/tmp/a.sock")
        let second = LeoTunnelOrphanRecord(pid: 2, startTime: 2, socketPath: "/tmp/b.sock")
        store.record(first)
        store.record(second)

        store.clear(matching: first)

        #expect(store.records() == [second])
        #expect(LeoTunnelOrphanStore(defaults: defaults, key: "orphan").records() == [second])
    }

    @Test func recordingTheSameSocketReplacesItsRecord() {
        let store = LeoTunnelOrphanStore(defaults: LeoInMemoryDefaults(), key: "orphan")
        let old = LeoTunnelOrphanRecord(pid: 1, startTime: 1, socketPath: "/tmp/a.sock")
        let new = LeoTunnelOrphanRecord(pid: 2, startTime: 2, socketPath: "/tmp/a.sock")
        store.record(old)
        store.record(new)

        #expect(store.records() == [new])
        store.clear(matching: old)
        #expect(store.records() == [new])
    }

    @Test func everyLiveRecordIsReapedAndOnlyTheLiveOnesAreSignalled() {
        let store = LeoTunnelOrphanStore(defaults: LeoInMemoryDefaults(), key: "orphan")
        let first = LeoTunnelOrphanRecord(pid: 1, startTime: 10, socketPath: LeoTunnelTestSupport.socketPath())
        let second = LeoTunnelOrphanRecord(pid: 2, startTime: 20, socketPath: LeoTunnelTestSupport.socketPath())
        let recycled = LeoTunnelOrphanRecord(pid: 3, startTime: 30, socketPath: LeoTunnelTestSupport.socketPath())
        [first, second, recycled].forEach(store.record)
        var alive: Set<Int32> = [1, 2]
        var signalled: [Int32] = []
        var sleeps = 0

        store.reapAtLaunch(
            inspector: { pid in
                switch pid {
                case 3: 31
                case _ where alive.contains(pid): pid == 1 ? 10 : 20
                default: nil
                }
            },
            signaller: { pid, _ in signalled.append(pid); alive.remove(pid) },
            sleep: { _ in sleeps += 1 }
        )

        #expect(Set(signalled) == [1, 2])
        #expect(sleeps == 1)
        #expect(store.records() == [recycled])
    }

    /// Builds before the set existed stored one bare record under the key.
    @Test func aSingleRecordStoredByAnOlderBuildIsStillLoadedAndReaped() throws {
        let defaults = LeoInMemoryDefaults()
        let path = LeoTunnelTestSupport.socketPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        let old = LeoTunnelOrphanRecord(pid: 42, startTime: 99, socketPath: path)
        defaults.set(try JSONEncoder().encode(old), forKey: "orphan")
        let store = LeoTunnelOrphanStore(defaults: defaults, key: "orphan")
        var signals: [Int32] = []
        var alive = true

        #expect(store.records() == [old])
        store.reapAtLaunch(
            inspector: { _ in alive ? 99 : nil },
            signaller: { _, signal in signals.append(signal); alive = false },
            sleep: { _ in }
        )

        #expect(signals == [SIGTERM])
        #expect(store.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(defaults.data(forKey: "orphan") == nil)
    }

    private func freshDefaults() -> UserDefaults {
        LeoInMemoryDefaults()
    }
}
