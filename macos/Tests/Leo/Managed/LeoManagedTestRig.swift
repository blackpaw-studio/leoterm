import Foundation

@testable import Ghostty
@testable import LeoKit

/// One ordered timeline across every managed-install seam, so tests assert
/// the exact interleaving of file ops, process runs and SMAppService calls.
enum LeoManagedEvent: Equatable, Sendable {
    case fs(LeoFileOp)
    case run([String])
    case agent(String)
}

final class LeoManagedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LeoManagedEvent] = []

    var events: [LeoManagedEvent] { lock.withLock { storage } }

    func append(_ event: LeoManagedEvent) { lock.withLock { storage.append(event) } }
    func clear() { lock.withLock { storage.removeAll() } }
}

/// Scripted `SMAppService` stand-in. `status` answers from a queue (the last
/// value repeats); register/unregister may be made to throw once.
final class LeoFakeLaunchAgent: LeoLaunchAgentService, @unchecked Sendable {
    struct Failure: Error, Equatable {}

    private let lock = NSLock()
    private let log: LeoManagedEventLog
    private var statuses: [LeoLaunchAgentStatus]
    private var registerFailures = 0
    private var unregisterFailures = 0
    private(set) var statusReads = 0

    init(log: LeoManagedEventLog, status: LeoLaunchAgentStatus...) {
        self.log = log
        statuses = status.isEmpty ? [.notRegistered] : status
    }

    func script(status: LeoLaunchAgentStatus...) { lock.withLock { statuses = status } }
    func failNextRegister() { lock.withLock { registerFailures += 1 } }
    func failNextUnregister() { lock.withLock { unregisterFailures += 1 } }

    var calls: Int { log.events.filter { if case .agent = $0 { true } else { false } }.count + lock.withLock { statusReads } }

    func status() -> LeoLaunchAgentStatus {
        lock.withLock {
            statusReads += 1
            return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        }
    }

    func register() async throws {
        log.append(.agent("register"))
        let fails = lock.withLock { () -> Bool in
            guard registerFailures > 0 else { return false }
            registerFailures -= 1
            return true
        }
        if fails { throw Failure() }
    }

    func unregister() async throws {
        log.append(.agent("unregister"))
        let fails = lock.withLock { () -> Bool in
            guard unregisterFailures > 0 else { return false }
            unregisterFailures -= 1
            return true
        }
        if fails { throw Failure() }
    }

    func openLoginItemsSettings() { log.append(.agent("openLoginItemsSettings")) }
}

/// Answers `hello` from a queue (the last value repeats) and counts probes.
final class LeoFakeProbe: LeoDaemonProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [LeoDaemonProbeResult]
    private(set) var count = 0

    init(_ results: LeoDaemonProbeResult...) { self.results = results.isEmpty ? [.absent] : results }

    func script(_ results: LeoDaemonProbeResult...) { lock.withLock { self.results = results } }
    var probes: Int { lock.withLock { count } }

    func probe() async -> LeoDaemonProbeResult {
        lock.withLock {
            count += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }
}

/// Answers each command line from a table keyed by its full argv
/// (executable first); an unscripted command exits 127.
final class LeoScriptedRunner: LeoProcessRunning, @unchecked Sendable {
    enum Reply: Sendable {
        case exit(Int32, stdout: String = "", stderr: String = "")
        case error(any Error & Sendable)
    }

    private let lock = NSLock()
    private let log: LeoManagedEventLog
    private var replies: [[String]: [Reply]] = [:]
    private(set) var timeouts: [[String]: TimeInterval] = [:]

    init(log: LeoManagedEventLog) { self.log = log }

    /// Queues replies for `argv`; the last one repeats.
    func on(_ argv: [String], _ replies: Reply...) { lock.withLock { self.replies[argv] = replies } }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> LeoProcessResult {
        let argv = [executable] + arguments
        log.append(.run(argv))
        let reply = lock.withLock { () -> Reply in
            timeouts[argv] = timeout
            guard var queue = replies[argv], !queue.isEmpty else { return .exit(127, stderr: "not scripted") }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            replies[argv] = queue
            return next
        }
        switch reply {
        case let .exit(status, stdout, stderr):
            return LeoProcessResult(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), status: status)
        case let .error(error):
            throw error
        }
    }
}

/// A clock whose sleeps return at once, having jumped to the deadline: a
/// 20 s wait runs in no wall time.
final class LeoJumpingClock: LeoDaemonClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: UInt64 = 0

    func now() -> UInt64 { lock.withLock { instant } }

    func sleep(until deadline: UInt64) async throws {
        try Task.checkCancellation()
        lock.withLock { instant = max(instant, deadline) }
    }

    var seconds: Double { Double(now()) / 1_000_000_000 }
}

/// Sequential tokens, like the in-memory file system's own.
final class LeoSequentialTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private let prefix: String

    init(prefix: String = "c") { self.prefix = prefix }

    func next() -> String { lock.withLock { counter += 1; return "\(prefix)\(counter)" } }
}
