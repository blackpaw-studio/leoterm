import Darwin
import Foundation
import OSLog

/// The outcome of an `LeoTunnel`'s underlying process exiting.
struct LeoTunnelExit: Equatable, Sendable {
    let status: Int32
    let stderrTail: String
}

enum LeoTunnelError: Error, Equatable, Sendable {
    case launchFailed(String)
    case exitedBeforeReady(status: Int32, stderrTail: String)
    case notReady(stderrTail: String)
}

/// A dumb wrapper around a single `ssh -n -N -L ...` `Process`. `LeoTunnel` owns no
/// state machine: it launches the process, waits for the local socket to answer a
/// health probe, and reports process exit exactly once. Callers (e.g. host
/// selection) are responsible for retry/backoff policy.
final class LeoTunnel: @unchecked Sendable {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    private let executable: URL
    private let arguments: [String]
    private let localSocketPath: String

    /// Invoked repeatedly by the readiness loop. **Must honour cancellation** --
    /// `start()` races each call against the remaining time on `deadline` using a
    /// `TaskGroup`, and a probe that ignores cancellation will make that race hang
    /// until it returns on its own. In production the real probe is bounded by
    /// `LeoUnixSocketTransport`'s own per-call timeout, which satisfies this.
    private let healthProbe: @Sendable (String) async throws -> Bool
    /// `any Clock<Duration>` erases its `Instant` type, which makes `now`
    /// unusable for arithmetic/comparison outside a generic context. `clockBox`
    /// closes over the concrete clock once in `init` (where its `Instant` type
    /// is still known) and exposes only `Duration`-based operations.
    private let clockBox: LeoTunnelClockBox

    private let process = Process()
    private let stderrPipe = Pipe()
    private let exitQueue = DispatchQueue(label: "com.mitchellh.ghostty.leo-tunnel.exit")

    /// Guards every mutable field below, including the calls into `process` that
    /// transition its lifecycle (`run`/`terminate`). Using one lock for both lets
    /// `terminateAndWait()` and `start()` serialize their launch/termination intent:
    /// a terminate that lands before `run()` is observed makes `start()` a no-op
    /// that throws `.launchFailed` instead of leaking a process.
    private let lock = NSLock()
    private var launched = false
    private var terminationRequested = false
    private var pidValue: Int32?
    private var startTimeValue: TimeInterval?
    private var exitStatusValue: Int32?
    private var stderrBuffer = Data()
    private var stderrDrainedFlag = false
    private var exitDelivered = false
    private var onExitCallback: (@Sendable (LeoTunnelExit) -> Void)?

    /// Fires exactly once, after the process has exited AND its stderr pipe has
    /// reached EOF, on a private queue (never the main thread, never the
    /// `MainActor`). Set this before calling `start()`; a value assigned after
    /// both conditions are already satisfied will never be delivered.
    var onExit: (@Sendable (LeoTunnelExit) -> Void)? {
        get { lock.withLock { onExitCallback } }
        set { lock.withLock { onExitCallback = newValue } }
    }

    private var onLaunchCallback: (@Sendable (_ pid: Int32, _ startTime: TimeInterval) -> Void)?

    /// Fires exactly once, synchronously right after the process has
    /// launched (before any readiness probing begins) -- so a caller that
    /// wants to record an orphan-reap record can do so before a long or
    /// gated health probe, not after it. Set this before calling `start()`.
    var onLaunch: (@Sendable (_ pid: Int32, _ startTime: TimeInterval) -> Void)? {
        get { lock.withLock { onLaunchCallback } }
        set { lock.withLock { onLaunchCallback = newValue } }
    }

    var pid: Int32? { lock.withLock { pidValue } }
    var processStartTime: TimeInterval? { lock.withLock { startTimeValue } }
    /// True as soon as the process has exited, independent of whether stderr has
    /// finished draining yet.
    var hasExited: Bool { lock.withLock { exitStatusValue != nil } }

    init(
        executable: URL,
        arguments: [String],
        localSocketPath: String,
        healthProbe: @escaping @Sendable (String) async throws -> Bool,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.executable = executable
        self.arguments = arguments
        self.localSocketPath = localSocketPath
        self.healthProbe = healthProbe
        self.clockBox = leoTunnelMakeClockBox(clock)
    }

    func start() async throws {
        try removeStaleSocket()
        installHandlers()
        try launchProcess()
        // Anchored here, right after the process is running, not in `init`: a
        // caller that constructs the tunnel and only calls `start()` later
        // (or is delayed getting scheduled) must still get the full 6s budget.
        let readinessOrigin = clockBox.elapsed()
        do {
            try await withTaskCancellationHandler(
                operation: { try await awaitReadiness(origin: readinessOrigin) },
                onCancel: { self.terminateAndWait() }
            )
        } catch {
            // Any failure out of the readiness wait -- including a probe that
            // throws CancellationError on its own, which `onCancel` above would
            // not otherwise observe -- must not leak the child process.
            terminateAndWait()
            throw error
        }
    }

    /// Synchronous, idempotent, and safe to call concurrently -- including from
    /// `applicationWillTerminate` and from inside `onExit` itself. Never waits for
    /// `onExit` delivery (which happens on `exitQueue`, not here), so it cannot
    /// deadlock against it. Every caller returns only once the process is
    /// confirmed gone: SIGTERM, wait up to 1s, SIGKILL, then wait unbounded
    /// (SIGKILL cannot be ignored).
    func terminateAndWait() {
        lock.lock()
        let wasLaunched = launched
        terminationRequested = true
        if wasLaunched, process.isRunning { process.terminate() }
        lock.unlock()

        guard wasLaunched else { return }

        waitForExit(upTo: 1)

        let stillRunning = process.isRunning
        if stillRunning, let target = pid {
            _ = Darwin.kill(target, SIGKILL)
        }
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    // MARK: - Launch

    private func launchProcess() throws {
        lock.lock()
        guard !terminationRequested else {
            lock.unlock()
            throw LeoTunnelError.launchFailed("terminated before the process could start")
        }
        process.executableURL = executable
        process.arguments = arguments
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            lock.unlock()
            Self.logger.error("launch failed executable=\(self.executable.path, privacy: .public) argv=\(self.arguments.joined(separator: " "), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw LeoTunnelError.launchFailed(error.localizedDescription)
        }
        launched = true
        let launchedPID = process.processIdentifier
        pidValue = launchedPID
        let launchedStartTime = Self.startTime(of: launchedPID)
        startTimeValue = launchedStartTime
        let terminateNow = terminationRequested
        let launchCallback = onLaunchCallback
        lock.unlock()

        Self.logger.log("launched pid=\(launchedPID) executable=\(self.executable.path, privacy: .public) argv=\(self.arguments.joined(separator: " "), privacy: .public)")

        if let launchCallback, let launchedStartTime {
            launchCallback(launchedPID, launchedStartTime)
        }

        if terminateNow {
            terminateAndWait()
        }
    }

    private func removeStaleSocket() throws {
        if FileManager.default.fileExists(atPath: localSocketPath) {
            try FileManager.default.removeItem(atPath: localSocketPath)
        }
    }

    private func installHandlers() {
        let readHandle = stderrPipe.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.markStderrDrained()
            } else {
                self.appendStderr(data)
            }
        }
        process.terminationHandler = { [weak self] finished in
            self?.markExited(status: finished.terminationStatus)
        }
    }

    // MARK: - Readiness

    private func awaitReadiness(origin: Duration) async throws {
        let deadline = origin + .seconds(6)
        while true {
            if hasExited {
                await drainStderrBestEffort()
                throw exitedBeforeReadyError()
            }
            try Task.checkCancellation()
            guard clockBox.elapsed() < deadline else {
                terminateAndWait()
                throw LeoTunnelError.notReady(stderrTail: currentStderrTail())
            }
            let healthy = try await raceProbe(deadline: deadline)
            if healthy == true {
                if hasExited {
                    await drainStderrBestEffort()
                    throw exitedBeforeReadyError()
                }
                return
            }
            if healthy == nil {
                terminateAndWait()
                throw LeoTunnelError.notReady(stderrTail: currentStderrTail())
            }
            let nextElapsed = min(clockBox.elapsed() + .milliseconds(100), deadline)
            try await clockBox.sleepUntilElapsed(nextElapsed)
        }
    }

    /// Races `healthProbe` against the ABSOLUTE `deadline` (elapsed since
    /// `start()`'s readiness origin). `nil` means the deadline won; a probe
    /// error other than `CancellationError` counts as unhealthy (`false`)
    /// rather than failing the race. The timer child sleeps until the absolute
    /// deadline, never a relative duration computed before it was scheduled --
    /// a relative sleep registered after the manual clock in tests has already
    /// advanced past it would park the timer forever. Structured: the loser is
    /// cancelled by the group when this function returns, nothing is detached.
    private func raceProbe(deadline: Duration) async throws -> Bool? {
        try await withThrowingTaskGroup(of: Bool?.self) { group in
            group.addTask { [healthProbe, localSocketPath] in
                do {
                    return try await healthProbe(localSocketPath)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return false
                }
            }
            group.addTask { [clockBox] in
                try await clockBox.sleepUntilElapsed(deadline)
                return nil
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func exitedBeforeReadyError() -> LeoTunnelError {
        lock.withLock {
            .exitedBeforeReady(status: exitStatusValue ?? -1, stderrTail: Self.decodedTail(stderrBuffer))
        }
    }

    private func currentStderrTail() -> String {
        lock.withLock { Self.decodedTail(stderrBuffer) }
    }

    /// Bounded best-effort wait for the stderr pipe to reach EOF so an early-exit
    /// error can include whatever was already written. Stops immediately on
    /// cancellation (`Task.sleep` throws right away in that case) and just
    /// reports whatever tail has been captured so far, rather than busy-looping
    /// until the 1s deadline with a sleep that never actually waits.
    private func drainStderrBestEffort() async {
        let deadline = Date().addingTimeInterval(1)
        while !isStderrDrained, Date() < deadline, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 5_000_000)
            } catch {
                return
            }
        }
    }

    private var isStderrDrained: Bool { lock.withLock { stderrDrainedFlag } }

    // MARK: - State mutation (called from Process/Pipe callbacks)

    private func appendStderr(_ data: Data) {
        lock.lock()
        stderrBuffer.append(data)
        if stderrBuffer.count > Self.stderrCap {
            stderrBuffer = Self.trimmedTail(stderrBuffer, cap: Self.stderrCap)
        }
        lock.unlock()
    }

    private func markStderrDrained() {
        lock.withLock { stderrDrainedFlag = true }
        attemptDelivery()
    }

    private func markExited(status: Int32) {
        lock.withLock { exitStatusValue = status }
        attemptDelivery()
    }

    private func attemptDelivery() {
        let ready: (LeoTunnelExit, (@Sendable (LeoTunnelExit) -> Void)?)? = lock.withLock {
            guard !exitDelivered, let status = exitStatusValue, stderrDrainedFlag else { return nil }
            exitDelivered = true
            return (LeoTunnelExit(status: status, stderrTail: Self.decodedTail(stderrBuffer)), onExitCallback)
        }
        if let (exit, _) = ready {
            let tailPreview = String(exit.stderrTail.prefix(200))
            Self.logger.log("exited status=\(exit.status) stderrTailPreview=\(tailPreview, privacy: .public)")
        }
        guard let (exit, callback) = ready, let callback else { return }
        exitQueue.async { callback(exit) }
    }

    private func waitForExit(upTo seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    // MARK: - Static helpers

    private static let stderrCap = 4096

    private static func trimmedTail(_ data: Data, cap: Int) -> Data {
        var suffix = data.suffix(cap)
        while let first = suffix.first, first & 0b1100_0000 == 0b1000_0000 {
            suffix.removeFirst()
        }
        return Data(suffix)
    }

    private static func decodedTail(_ data: Data) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        let decoded = String(decoding: data, as: UTF8.self)
        // Lossy decoding can replace an invalid byte with U+FFFD (3 UTF-8
        // bytes), which can grow the string past `stderrCap` even though the
        // source `Data` was already trimmed to it. Drop leading characters
        // until it fits again so callers can rely on the byte-cap invariant.
        guard decoded.utf8.count > stderrCap else { return decoded }
        var trimmed = Substring(decoded)
        while trimmed.utf8.count > stderrCap, !trimmed.isEmpty {
            trimmed.removeFirst()
        }
        return String(trimmed)
    }

    private static func startTime(of pid: Int32) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard bytes == size else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    }
}

/// Type-erased, `Duration`-only view of a `Clock<Duration>`. See the comment on
/// `LeoTunnel.clockBox` for why this exists.
private struct LeoTunnelClockBox: Sendable {
    /// Sleeps until `elapsed` (a `Duration` since this box was created) has
    /// passed, translated back into the underlying clock's own `Instant`.
    /// Always absolute: never derive a relative `sleep(for:)` duration from
    /// `elapsed()` and pass it to a task scheduled later, since anything that
    /// can advance the clock between those two steps would park the sleep
    /// past its intended deadline.
    let sleepUntilElapsed: @Sendable (Duration) async throws -> Void
    /// `Duration` elapsed since this box was created.
    let elapsed: @Sendable () -> Duration
}

private func leoTunnelMakeClockBox<C: Clock>(_ clock: C) -> LeoTunnelClockBox where C.Duration == Duration {
    let origin = clock.now
    return LeoTunnelClockBox(
        sleepUntilElapsed: { targetElapsed in
            try await clock.sleep(until: origin.advanced(by: targetElapsed), tolerance: nil)
        },
        elapsed: { origin.duration(to: clock.now) }
    )
}
