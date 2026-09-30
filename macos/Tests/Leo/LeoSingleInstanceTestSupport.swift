import Darwin
import Foundation
import Testing

@testable import Ghostty

/// Records what the single-instance gate asked the app to do instead of
/// doing it.
final class LeoGateSpy {
    static let bundleID = "studio.blackpaw.leo.macos.tests"

    private(set) var activated: [String] = []
    private(set) var alerts: [LeoInstanceLockRefusal] = []
    private(set) var exits: [Int32] = []
    /// The pids of quitting holders waited out, in order.
    private(set) var waits: [pid_t] = []
    private(set) var pauses = 0

    func activate(_ bundleID: String) { activated.append(bundleID) }
    func alert(_ refusal: LeoInstanceLockRefusal) { alerts.append(refusal) }
    func exit(_ status: Int32) { exits.append(status) }
    /// Records the wait and returns at once, as for a process already gone.
    func waitForExit(_ pid: pid_t) { waits.append(pid) }
    /// Records the pause and returns at once.
    func pauseForRelease() { pauses += 1 }

    /// A gate for `bundleID`. Every wait and pause is recorded; `onWait`
    /// stands in for the quitting holder's process ending, `onPause` for
    /// time passing while it releases its lock.
    func gate(
        isTestHost: Bool = false,
        acquire: @escaping (String) -> LeoInstanceLockAttempt,
        onWait: ((pid_t) -> Void)? = nil,
        onPause: (() -> Void)? = nil
    ) -> LeoSingleInstance {
        LeoSingleInstance(
            bundleIdentifier: Self.bundleID, isTestHost: isTestHost,
            acquireLock: acquire,
            waitForExit: { [self] pid in
                waitForExit(pid)
                onWait?(pid)
            },
            pauseForRelease: { [self] in
                pauseForRelease()
                onPause?()
            },
            activateOther: activate, alert: alert, terminate: exit
        )
    }
}

/// A claim or lock another copy holds: a seam or the test sets it, and
/// dropping it stands in for that copy's process ending.
final class LeoHeld<Value>: @unchecked Sendable {
    private let mutex = NSLock()
    private var value: Value?

    init(_ value: Value? = nil) { self.value = value }

    var holds: Bool { mutex.withLock { value != nil } }

    func set(_ value: Value) { mutex.withLock { self.value = value } }

    func drop() { mutex.withLock { value = nil } }

    func read<Result>(_ body: (Value?) -> Result) -> Result { mutex.withLock { body(value) } }
}

/// Runs `body` on its own thread -- as a copy launching beside the test
/// would -- and waits for it. None of this may block on a live copy: still
/// running after `limit`, it's recorded as blocked, and `unblock` (that
/// copy going) lets it finish instead of hanging the suite.
final class LeoOffThread<Result>: @unchecked Sendable {
    private static var limit: DispatchTimeInterval { .seconds(10) }
    private let body: () -> Result
    private let done = DispatchSemaphore(value: 0)
    private var result: Result?

    private init(_ body: @escaping () -> Result) { self.body = body }

    static func run(_ body: @escaping () -> Result, unblock: () -> Void = {}) -> Result? {
        let run = LeoOffThread(body)
        Thread {
            run.result = run.body()
            run.done.signal()
        }.start()
        guard run.done.wait(timeout: .now() + limit) == .timedOut else { return run.result }
        Issue.record("blocked behind a live copy")
        unblock()
        guard run.done.wait(timeout: .now() + limit) == .success else {
            Issue.record("still blocked after the live copy went")
            return nil
        }
        return run.result
    }
}

/// The instance lock file for `LeoGateSpy.bundleID` in a test directory.
enum LeoInstanceLockTestFile {
    static func acquire(in directory: LeoTestSocketDirectory) -> LeoInstanceLockAttempt {
        LeoInstanceLock.acquire(bundleIdentifier: LeoGateSpy.bundleID, in: directory.url)
    }

    /// A held lock, or the test stops.
    static func held(in directory: LeoTestSocketDirectory) throws -> LeoInstanceLock {
        let attempt = acquire(in: directory)
        guard case .acquired(let lock) = attempt else {
            throw LeoInstanceLockTestError.notAcquired("\(attempt)")
        }
        return lock
    }

    static func path(in directory: LeoTestSocketDirectory) -> String {
        directory.path(LeoInstanceLock.fileName(for: LeoGateSpy.bundleID))
    }

    /// Rewrites the file in place, not replacing it, so a holder's lock
    /// stays on this very file.
    static func overwrite(in directory: LeoTestSocketDirectory, with contents: String) {
        let writer = open(path(in: directory), O_WRONLY | O_TRUNC | O_CLOEXEC)
        #expect(writer >= 0)
        #expect(Array(contents.utf8).withUnsafeBytes { write(writer, $0.baseAddress, $0.count) } == contents.utf8.count)
        close(writer)
    }

    static func contents(in directory: LeoTestSocketDirectory) -> String? {
        FileManager.default.contents(atPath: path(in: directory)).flatMap { String(bytes: $0, encoding: .utf8) }
    }
}

enum LeoInstanceLockTestError: Error {
    case notAcquired(String)
}

/// Real child processes, to wait out.
enum LeoTestProcess {
    /// Starts `path`; the caller reaps it with `waitpid`.
    static func spawn(_ path: String, _ arguments: [String] = []) throws -> pid_t {
        var pid: pid_t = 0
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let status = posix_spawn(&pid, path, nil, nil, argv, nil)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        return pid
    }

    /// The pid of a process that has exited and been reaped.
    static func gone() throws -> pid_t {
        let pid = try spawn("/usr/bin/true")
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        return pid
    }
}
