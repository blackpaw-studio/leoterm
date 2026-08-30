import Foundation
import os

/// A running `leo host forward` process: streams its stdout lines and lets the
/// caller tear it down. Abstracted so `LeoForwardManager` can be tested without
/// spawning a real `ssh`/`leo` process.
protocol ForwardHandle: Sendable {
    var lines: AsyncStream<String> { get }
    func terminate()
}

/// Launches `leo host forward …`. Injected into `LeoForwardManager`; the
/// production implementation is `ProcessForwardLauncher`.
protocol ForwardLauncher: Sendable {
    func launch(args: [String]) async -> ForwardHandle
}

/// Owns a persistent SSH socket forward to one remote leo host.
///
/// `leo host forward <name> --json` establishes a ControlMaster + a
/// StreamLocalForward of the remote daemon socket to a local path, then blocks.
/// Its contract: the local socket path arrives on the first stdout line once
/// the forward is healthy; the process exiting before that means setup failed.
/// We keep the process alive for the forward's lifetime and `terminate()` it on
/// teardown.
///
/// Two hazards this actor guards against:
/// - **A hung forward** (unreachable host, an `ssh` password/host-key prompt)
///   never prints a socket line. `start()` therefore bounds its wait by
///   `startTimeout` and tears the process down instead of suspending forever.
/// - **A forward that dies later** (ssh drop, remote reboot) leaves a cached
///   socket path pointing at nothing. The stdout stream ending after a healthy
///   start signals that; `onTerminated` lets the owner (the host registry)
///   invalidate its cached connection so the next acquire rebuilds it.
actor LeoForwardManager {
    /// Default bound on how long `start()` waits for the first socket line
    /// before giving up and terminating the forward process.
    static let defaultStartTimeout: Duration = .seconds(15)

    /// Decode the local socket path from a `leo host forward --json` stdout
    /// line. Returns `nil` for non-JSON / pre-connect log lines.
    static func parseSocketPath(jsonLine: String) -> String? {
        guard let data = jsonLine.data(using: .utf8),
              let line = try? JSONDecoder().decode(ForwardLine.self, from: data)
        else { return nil }
        return line.socket
    }

    static func forwardArgs(host: String) -> [String] { ["host", "forward", host, "--json"] }
    /// Args for an explicit `leo host forward <name> --stop`. Reserved as a
    /// graceful-teardown fallback: `stop()` currently SIGTERMs the foreground
    /// forward process instead (leo's documented "kill to tear down" model).
    /// Switch `stop()` to invoke this if live testing shows SIGTERM leaves a
    /// stale ControlMaster or socket behind.
    static func stopArgs(host: String) -> [String] { ["host", "forward", host, "--stop"] }

    let host: String
    private let launcher: ForwardLauncher
    /// Bound on the wait for the first socket line. Injectable so tests don't
    /// have to wait out the production timeout.
    private let startTimeout: Duration
    private var handle: ForwardHandle?
    /// The forwarded socket path once the forward is healthy. Non-`nil` implies
    /// a live `handle`.
    private var socketPath: String?
    /// True between `launcher.launch(…)` being awaited and the handle being
    /// stored, so a re-entrant `start()` waits instead of spawning a second
    /// process.
    private var isLaunching = false
    /// Set by `stop()` so the resulting stream end is understood as a
    /// deliberate teardown rather than a forward that died on us.
    private var isStopped = false
    /// True once the forward's stdout stream has ended, so a waiter that
    /// registers *after* the process already exited fails immediately instead of
    /// waiting out `startTimeout`.
    private var isFinished = false
    /// Latched when the timeout branch wins the start race. Any waiter that
    /// would register afterwards bails out instead, so the losing branch can
    /// never park on a continuation nobody will resume. Callers that joined the
    /// same start share this outcome; the next `start()` clears it.
    private var isTimedOut = false
    /// Incremented per launch. A monitor from an earlier epoch (a handle we
    /// already stopped) must not mutate state belonging to its replacement.
    private var epoch: UInt64 = 0
    /// Callers suspended in `start()` waiting for the first socket line.
    private var socketWaiters: [CheckedContinuation<String?, Never>] = []
    private var monitorTask: Task<Void, Never>?
    /// Why the most recent wait ended without a socket path.
    private var startFailure: LeoError = .daemonUnreachable
    /// Invoked with `host` when a *healthy* forward dies on its own.
    private var onTerminated: (@Sendable (String) -> Void)?

    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-forward")

    init(
        host: String,
        launcher: ForwardLauncher = ProcessForwardLauncher(),
        startTimeout: Duration = LeoForwardManager.defaultStartTimeout
    ) {
        self.host = host
        self.launcher = launcher
        self.startTimeout = startTimeout
    }

    /// Register the callback fired when a healthy forward dies unexpectedly.
    /// Not called for a deliberate `stop()`.
    func setTerminationHandler(_ handler: (@Sendable (String) -> Void)?) {
        onTerminated = handler
    }

    /// Start the forward and resolve to the local socket path once healthy.
    /// Idempotent: a second call while the forward is up returns the same path,
    /// and a call that races an in-flight start joins it rather than spawning a
    /// second process.
    ///
    /// Throws if the process ends before printing a socket path, or if it never
    /// prints one within `startTimeout`.
    func start() async throws(LeoError) -> String {
        if let socketPath { return socketPath }
        isStopped = false
        isFinished = false
        isTimedOut = false
        startFailure = .daemonUnreachable
        if handle == nil, !isLaunching { await launch() }
        guard let socket = await waitForSocket() else {
            let failure = startFailure
            stop()
            throw failure
        }
        return socket
    }

    /// Tear down the forward by SIGTERM-ing the `leo host forward` process.
    /// leo's process is expected to clean up its own ControlMaster + local
    /// socket on exit ("kill to tear down"); that self-cleanup is the one
    /// teardown behavior that still needs live verification against a real
    /// host (see `stopArgs` for the explicit `--stop` fallback).
    func stop() {
        isStopped = true
        // Orphan the current monitor: anything it reports from here on belongs
        // to a handle we no longer own.
        epoch &+= 1
        handle?.terminate()
        handle = nil
        socketPath = nil
        monitorTask?.cancel()
        monitorTask = nil
        resolveWaiters(with: nil)
    }

    /// Whether no forward is currently held. Used by tests to await teardown
    /// without sleeping on a guess.
    var isIdle: Bool { handle == nil && socketPath == nil }

    // MARK: - Internals

    private func launch() async {
        isLaunching = true
        let handle = await launcher.launch(args: Self.forwardArgs(host: host))
        isLaunching = false
        // A `stop()` landed while we were launching: don't adopt the process.
        guard !isStopped else {
            handle.terminate()
            return
        }
        epoch &+= 1
        let epoch = epoch
        self.handle = handle
        monitorTask = Task { [weak self] in await self?.monitor(handle, epoch: epoch) }
    }

    /// Consume the forward's stdout: the first socket line resolves `start()`,
    /// and the stream ending means the process exited. Every mutation is gated
    /// on `epoch` so a monitor left over from a stopped handle is inert.
    private func monitor(_ handle: ForwardHandle, epoch: UInt64) async {
        for await line in handle.lines {
            guard self.epoch == epoch else { return }
            guard let socket = Self.parseSocketPath(jsonLine: line) else { continue }
            adopt(socket: socket, epoch: epoch)
        }
        handleStreamEnd(epoch: epoch)
    }

    private func adopt(socket: String, epoch: UInt64) {
        guard self.epoch == epoch, socketPath == nil else { return }
        socketPath = socket
        resolveWaiters(with: socket)
    }

    /// The forward process exited. If it had been healthy, notify the owner so a
    /// dead socket path isn't served forever.
    private func handleStreamEnd(epoch: UInt64) {
        guard self.epoch == epoch else { return }
        let wasHealthy = socketPath != nil
        isFinished = true
        handle = nil
        socketPath = nil
        // Don't clobber a latched timeout message with the generic error.
        if !isTimedOut { startFailure = .daemonUnreachable }
        resolveWaiters(with: nil)
        guard !isStopped, wasHealthy else { return }
        Self.logger.warning("forward to \(self.host, privacy: .public) exited unexpectedly")
        onTerminated?(host)
    }

    /// Suspend until the socket line arrives, or `startTimeout` elapses.
    /// Resolves to `nil` on timeout or on the process exiting first.
    private func waitForSocket() async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await self.awaitSocketLine() }
            group.addTask {
                try? await Task.sleep(for: self.startTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            if first == nil { await self.latchTimeout() }
            group.cancelAll()
            return first
        }
    }

    private func awaitSocketLine() async -> String? {
        if let socketPath { return socketPath }
        // Never register once the race is already decided (or the caller is
        // cancelled): the resolver may have run already, and the continuation
        // would be parked forever.
        if isFinished || isTimedOut || Task.isCancelled { return nil }
        return await withCheckedContinuation { continuation in
            socketWaiters.append(continuation)
        }
    }

    /// Latch the timeout outcome unconditionally, so a waiter that has not
    /// registered yet bails out instead of parking on a continuation nobody
    /// resumes, and fail any waiter that already did register.
    private func latchTimeout() {
        isTimedOut = true
        if !isFinished {
            startFailure = .daemon(message: "forward to \(host) timed out after \(startTimeout)")
        }
        resolveWaiters(with: nil)
    }

    private func resolveWaiters(with value: String?) {
        let pending = socketWaiters
        socketWaiters.removeAll()
        for waiter in pending { waiter.resume(returning: value) }
    }

    private struct ForwardLine: Decodable { let socket: String? }
}

/// Production `ForwardLauncher`: runs the real `leo host forward` and streams
/// its stdout line-by-line.
struct ProcessForwardLauncher: ForwardLauncher {
    let leoExecutable: String

    init(leoExecutable: String = LeoCLI.executablePath) {
        self.leoExecutable = leoExecutable
    }

    func launch(args: [String]) async -> ForwardHandle {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: leoExecutable)
        proc.arguments = args
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()

        let (stream, continuation) = AsyncStream<String>.makeStream()
        let box = ProcessBox(proc)
        proc.terminationHandler = { _ in continuation.finish() }

        do {
            try proc.run()
        } catch {
            continuation.finish()
            return ProcessForwardHandle(lines: stream, box: box)
        }

        // Forward stdout lines until the pipe closes (process exits).
        Task.detached {
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    continuation.yield(line)
                }
            } catch {}
            continuation.finish()
        }
        return ProcessForwardHandle(lines: stream, box: box)
    }
}

/// `ForwardHandle` backed by a real `Process`.
private struct ProcessForwardHandle: ForwardHandle {
    let lines: AsyncStream<String>
    let box: ProcessBox
    func terminate() { box.terminate() }
}

/// Guards a non-`Sendable` `Process` so it can cross isolation boundaries for
/// the sole purpose of termination.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()

    init(_ process: Process) { self.process = process }

    func terminate() {
        lock.withLock { if process.isRunning { process.terminate() } }
    }
}
