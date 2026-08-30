import Foundation

/// Shared `Process` runner for the leo CLI fallbacks. Launches `executable`
/// with `args`, reads stdout to EOF, waits for exit, and maps failures to
/// `LeoError`. Callers that need to stay off a cooperative thread should hop
/// to a background queue themselves (see `LeoHostCatalog`).
///
/// Both pipes are drained concurrently: a `leo` invocation that tunnels over
/// `ssh` can emit far more than a pipe buffer's worth of warnings on stderr,
/// and an undrained pipe blocks the child forever. The run is also bounded by
/// `timeout` so a prompting or wedged child can't hang the caller.
enum LeoProcessRunner {
    /// Default wall-clock bound for a CLI invocation. Generous because a remote
    /// call may set up an SSH connection first.
    static let defaultTimeout: TimeInterval = 30
    /// How long to wait for a SIGTERM'd child to exit and its pipes to drain.
    private static let terminationGrace: TimeInterval = 2
    /// Bytes of stderr retained (tail) for error messages.
    private static let stderrTailLimit = 4096

    /// Run `executable args…` and return stdout. Throws `LeoError.daemonUnreachable`
    /// if the process can't launch, or `LeoError.daemon` on a non-zero exit or a
    /// timeout.
    static func run(
        executable: String,
        args: [String],
        timeout: TimeInterval = defaultTimeout
    ) throws(LeoError) -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }

        do {
            try proc.run()
        } catch {
            throw LeoError.daemonUnreachable
        }

        // Drain both pipes event-driven so neither can wedge the child, and so
        // the timeout below is actually reachable. No thread ever blocks in a
        // read, which keeps the forced close below race-free.
        let drains = DispatchGroup()
        let stdoutDrain = PipeDrain(handle: stdout.fileHandleForReading, group: drains)
        let stderrDrain = PipeDrain(
            handle: stderr.fileHandleForReading, group: drains, tailLimit: stderrTailLimit)
        // Whether the child exits or is killed, the pipes are always closed out:
        // a child that leaked the write end (ssh's ControlMaster) never gives us
        // EOF, so waiting on it alone would hang.
        defer { finishDrains(stdoutDrain, stderrDrain, group: drains) }

        let description = "leo \(args.joined(separator: " "))"
        guard exited.wait(timeout: .now() + timeout) == .success else {
            kill(proc, exited: exited)
            // The `defer` above closes the pipes out on this path.
            throw LeoError.daemon(message: "\(description) timed out after \(Int(timeout))s")
        }
        finishDrains(stdoutDrain, stderrDrain, group: drains)

        guard proc.terminationStatus == 0 else {
            throw LeoError.daemon(message: "\(description) exited \(proc.terminationStatus)\(stderrDrain.suffix)")
        }
        return stdoutDrain.value
    }

    /// SIGTERM, then SIGKILL if the child ignores it.
    private static func kill(_ proc: Process, exited: DispatchSemaphore) {
        proc.terminate()
        guard exited.wait(timeout: .now() + terminationGrace) == .timedOut else { return }
        Darwin.kill(proc.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + terminationGrace)
    }

    /// Give the drains a moment to observe EOF, then tear them down. Idempotent,
    /// so the `defer` on the throwing paths is harmless.
    private static func finishDrains(_ drains: PipeDrain..., group: DispatchGroup) {
        if group.wait(timeout: .now() + terminationGrace) == .success { return }
        for drain in drains { drain.finish() }
    }

    /// `run(executable:args:timeout:)` off the cooperative thread pool. `run` is
    /// blocking (it waits on the child), so every async caller must hop to a
    /// background queue rather than parking a cooperative thread.
    static func runAsync(
        executable: String,
        args: [String],
        timeout: TimeInterval = defaultTimeout
    ) async throws(LeoError) -> Data {
        let result: Result<Data, LeoError> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: .success(
                        try run(executable: executable, args: args, timeout: timeout)))
                } catch let error as LeoError {
                    continuation.resume(returning: .failure(error))
                } catch {
                    continuation.resume(returning: .failure(LeoError.daemonUnreachable))
                }
            }
        }
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}

/// Event-driven pipe drain: a `readabilityHandler` accumulates output, so no
/// thread ever parks inside a blocking read and the handle can be closed at any
/// time without racing a reader. Optionally keeps only the trailing `tailLimit`
/// bytes (enough for an error message, bounded memory).
private final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let group: DispatchGroup
    private let tailLimit: Int?
    private let lock = NSLock()
    private var storage = Data()
    private var isDone = false

    init(handle: FileHandle, group: DispatchGroup, tailLimit: Int? = nil) {
        self.handle = handle
        self.group = group
        self.tailLimit = tailLimit
        group.enter()
        handle.readabilityHandler = { [weak self] handle in self?.consume(handle) }
    }

    /// Handler callback. Empty data means EOF. Serialized against `finish()` so
    /// a read can never touch a closed descriptor.
    private func consume(_ handle: FileHandle) {
        lock.withLock {
            guard !isDone else { return }
            // The handler only fires when a read won't block, so this returns
            // immediately even though the lock is held.
            let data = handle.availableData
            guard !data.isEmpty else { return finishLocked() }
            storage.append(data)
            guard let tailLimit, storage.count > tailLimit else { return }
            // Re-base: a `Data` slice keeps its original indices.
            storage = Data(storage.suffix(tailLimit))
        }
    }

    /// Stop draining and release the group. Idempotent.
    func finish() { lock.withLock { finishLocked() } }

    private func finishLocked() {
        guard !isDone else { return }
        isDone = true
        handle.readabilityHandler = nil
        try? handle.close()
        group.leave()
    }

    var value: Data { lock.withLock { storage } }

    /// The captured text as a `": …"` message suffix, or `""` when empty.
    var suffix: String {
        let text = (String(bytes: value, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : ": \(text)"
    }
}
