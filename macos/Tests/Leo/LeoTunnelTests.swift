import Darwin
import Foundation
import Testing

@testable import Ghostty

@Suite(.serialized)
struct LeoTunnelTests {
    @Test func passesArgumentsWithoutShellRewriting() async {
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' \"$@\" >&2", "--", "one two", "three"],
            localSocketPath: LeoTunnelTestSupport.socketPath(),
            healthProbe: { _ in false }
        )
        defer { tunnel.terminateAndWait() }

        await #expect(throws: LeoTunnelError.exitedBeforeReady(status: 0, stderrTail: "one two\nthree\n")) {
            try await tunnel.start()
        }
    }

    @Test func forwardsArgumentsAndBecomesReadyAgainstFakeSSH() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: LeoTunnelTestSupport.healthProbe
        )
        defer { tunnel.terminateAndWait() }

        try await tunnel.start()
        #expect(tunnel.pid != nil)
    }

    @Test func removesStaleSocketBeforeLaunch() async throws {
        let path = LeoTunnelTestSupport.socketPath()
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path))
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: LeoTunnelTestSupport.healthProbe
        )
        defer { tunnel.terminateAndWait() }

        try await tunnel.start()
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func exitsBeforeReadyIncludesStderr() async throws {
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", "23")
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", nil) }
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: LeoTunnelTestSupport.healthProbe
        )
        defer { tunnel.terminateAndWait() }

        await #expect(throws: LeoTunnelError.exitedBeforeReady(status: 23, stderrTail: "auth failed\n")) {
            try await tunnel.start()
        }
    }

    @Test func missingExecutableReturnsLaunchFailed() async {
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/no/such/ssh"),
            arguments: [],
            localSocketPath: LeoTunnelTestSupport.socketPath(),
            healthProbe: { _ in false }
        )
        defer { tunnel.terminateAndWait() }
        do {
            try await tunnel.start()
            Issue.record("expected launchFailed")
        } catch let error as LeoTunnelError {
            guard case .launchFailed = error else {
                Issue.record("expected .launchFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func unhealthyEndpointNeverBecomesReady() async throws {
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_UNHEALTHY", "1")
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_UNHEALTHY", nil) }
        let clock = LeoTunnelManualClock()
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: LeoTunnelTestSupport.healthProbe,
            clock: clock
        )
        defer { tunnel.terminateAndWait() }
        let task = Task { try await tunnel.start() }
        defer { task.cancel() }
        await awaitCondition { tunnel.pid != nil }
        clock.advance(by: .seconds(6))

        await #expect(throws: LeoTunnelError.notReady(stderrTail: "")) { try await task.value }
        let pid = try #require(tunnel.pid)
        await awaitCondition { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
    }

    @Test func timesOutAfterManualClockAdvancesSixSecondsWithAnAlwaysFalseProbe() async throws {
        let clock = LeoTunnelManualClock()
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: { _ in false },
            clock: clock
        )
        defer { tunnel.terminateAndWait() }
        let task = Task { try await tunnel.start() }
        defer { task.cancel() }
        await awaitCondition { tunnel.pid != nil }
        clock.advance(by: .seconds(6))

        await #expect(throws: LeoTunnelError.notReady(stderrTail: "")) { try await task.value }
        let pid = try #require(tunnel.pid)
        await awaitCondition { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
    }

    @Test func cancellationTerminatesAChildWaitingForReadiness() async throws {
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_NEVER_BIND", "1")
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_NEVER_BIND", nil) }
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: { _ in false }
        )
        defer { tunnel.terminateAndWait() }
        let task = Task { try await tunnel.start() }
        defer { task.cancel() }
        await awaitCondition { tunnel.pid != nil }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(tunnel.pid)
        await awaitCondition { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
    }

    @Test func cancellationDuringAGatedProbeTerminatesTheChild() async throws {
        let gate = ProbeGate()
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: { _ in try await gate.enterAndWait() }
        )
        defer { tunnel.terminateAndWait() }
        let task = Task { try await tunnel.start() }
        defer { task.cancel() }
        await gate.waitUntilEntered()
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(tunnel.pid)
        await awaitCondition { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
    }

    @Test func exitDuringHealthyProbeStillThrowsExitedBeforeReady() async throws {
        let gate = ProbeGate()
        let path = LeoTunnelTestSupport.socketPath()
        let tunnel = LeoTunnel(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: try LeoTunnelTestSupport.arguments(socketPath: path),
            localSocketPath: path,
            healthProbe: { _ in try await gate.enterAndWait() }
        )
        defer { tunnel.terminateAndWait() }
        let task = Task { try await tunnel.start() }
        defer { task.cancel() }
        await gate.waitUntilEntered()
        let pid = try #require(tunnel.pid)
        _ = Darwin.kill(pid, SIGKILL)
        await awaitCondition { tunnel.hasExited }
        try #require(tunnel.hasExited)
        await gate.release(with: true)

        do {
            try await task.value
            Issue.record("expected exitedBeforeReady")
        } catch let error as LeoTunnelError {
            guard case .exitedBeforeReady = error else {
                Issue.record("expected .exitedBeforeReady, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

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

// MARK: - Test doubles

/// A manual `Clock<Duration>` for deterministic deadline tests. `advance(by:)`
/// jumps `now` forward and resolves any pending `sleep(until:)` whose deadline
/// has passed. The single pending sleep is tracked with a lock so an `advance`
/// that lands before a `sleep(until:)` call has registered is never lost: the
/// registration itself re-checks `now` under the same lock before parking.
/// Also cancellation-aware: a cancelled waiter is resumed with
/// `CancellationError` rather than left to hang forever, which would otherwise
/// deadlock a `TaskGroup` waiting on it to unwind after `cancelAll()`.
final class LeoTunnelManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Comparable {
        let offset: Duration
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
        func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
        func duration(to other: Self) -> Duration { other.offset - offset }
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var pendingDeadline: Instant?
    private var pendingResume: ((Result<Void, Error>) -> Void)?

    var now: Instant { lock.withLock { currentInstant } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if currentInstant >= deadline || Task.isCancelled {
                        let cancelled = Task.isCancelled && currentInstant < deadline
                        lock.unlock()
                        if cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume()
                        }
                        return
                    }
                    pendingDeadline = deadline
                    pendingResume = { continuation.resume(with: $0) }
                    lock.unlock()
                }
            },
            onCancel: { [weak self] in self?.cancelPending() }
        )
    }

    private func cancelPending() {
        lock.lock()
        let resume = pendingResume
        pendingDeadline = nil
        pendingResume = nil
        lock.unlock()
        resume?(.failure(CancellationError()))
    }

    func advance(by duration: Duration) {
        lock.lock()
        currentInstant = currentInstant.advanced(by: duration)
        var resume: ((Result<Void, Error>) -> Void)?
        if let deadline = pendingDeadline, deadline <= currentInstant {
            resume = pendingResume
            pendingDeadline = nil
            pendingResume = nil
        }
        lock.unlock()
        resume?(.success(()))
    }
}

/// Gates a `healthProbe` call so a test can synchronize on "the probe has been
/// entered" before doing something else (killing the child, cancelling the
/// task) and only then choose the probe's result. Cancellation-aware: if the
/// probe's `Task` is cancelled while parked, `enterAndWait()` resumes with
/// `CancellationError` instead of hanging. `waitUntilEntered()` and
/// `enterAndWait()` may race in either order without losing the signal.
actor ProbeGate {
    private var enteredAlready = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseValue: Bool?
    private var releaseContinuation: CheckedContinuation<Bool, Error>?

    func enterAndWait() async throws -> Bool {
        enteredAlready = true
        enteredContinuation?.resume()
        enteredContinuation = nil

        if let releaseValue {
            self.releaseValue = nil
            return releaseValue
        }
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    releaseContinuation = continuation
                }
            },
            onCancel: { [weak self] in Task { await self?.failWaiting() } }
        )
    }

    private func failWaiting() {
        releaseContinuation?.resume(throwing: CancellationError())
        releaseContinuation = nil
    }

    func waitUntilEntered() async {
        if enteredAlready { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release(with value: Bool) {
        if let releaseContinuation {
            releaseContinuation.resume(returning: value)
            self.releaseContinuation = nil
        } else {
            releaseValue = value
        }
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
