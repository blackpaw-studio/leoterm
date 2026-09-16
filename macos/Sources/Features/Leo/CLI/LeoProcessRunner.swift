import Darwin
import Foundation

struct LeoProcessResult: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

protocol LeoProcessRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> LeoProcessResult
}

struct LeoProcessRunner: LeoProcessRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval = 30) async throws -> LeoProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let state = LeoProcessRunState(continuation: continuation)
            process.terminationHandler = { process in
                state.finished(status: process.terminationStatus)
            }
            state.startTimeout(after: timeout, process: process)
            DispatchQueue.global(qos: .userInitiated).async {
                state.read(stdout.fileHandleForReading, isStandardOutput: true)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                state.read(stderr.fileHandleForReading, isStandardOutput: false)
            }
            do {
                try process.run()
            } catch {
                state.failed(LeoDaemonError.transport("Cannot run \(executable): \(error.localizedDescription)"))
            }
            }
        }
    }
}

/// `timeout` only sends SIGTERM. A child that ignores it (or a grandchild
/// that keeps inherited stdout/stderr pipes open after the direct child
/// exits) must never hang this call forever: `startTimeout` escalates to
/// SIGKILL 1s after the original deadline, then -- regardless of whether the
/// pipes have reached EOF yet -- force-completes 1s after that. The pipe
/// readers keep draining on their own background dispatches either way;
/// forced completion just stops waiting on them.
private final class LeoProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<LeoProcessResult, Error>
    private var stdout = Data()
    private var stderr = Data()
    private var readersRemaining = 2
    private var status: Int32?
    private var timedOut = false
    private var completed = false

    init(continuation: CheckedContinuation<LeoProcessResult, Error>) {
        self.continuation = continuation
    }

    func startTimeout(after timeout: TimeInterval, process: Process) {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self, weak process] in
            guard let self else { return }
            self.lock.lock()
            guard !self.completed else { self.lock.unlock(); return }
            self.timedOut = true
            self.lock.unlock()
            process?.terminate()
            self.escalateAfterGracePeriod(process: process)
        }
    }

    private func escalateAfterGracePeriod(process: Process?) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self, weak process] in
            guard let self else { return }
            self.lock.lock()
            let stillRunning = !self.completed
            self.lock.unlock()
            guard stillRunning else { return }
            if let process, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.forceComplete()
            }
        }
    }

    func read(_ handle: FileHandle, isStandardOutput: Bool) {
        let data = handle.readDataToEndOfFile()
        lock.lock()
        if isStandardOutput { stdout = data } else { stderr = data }
        readersRemaining -= 1
        completeIfReady()
        lock.unlock()
    }

    func finished(status: Int32) {
        lock.lock()
        self.status = status
        completeIfReady()
        lock.unlock()
    }

    func failed(_ error: Error) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        continuation.resume(throwing: error)
    }

    /// Forces completion (always as `.timeout`) once the post-SIGKILL drain
    /// grace period has elapsed, regardless of whether the pipe readers
    /// have reached EOF -- a lingering grandchild holding a pipe open must
    /// never hang the caller forever.
    private func forceComplete() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        continuation.resume(throwing: LeoDaemonError.timeout)
    }

    /// Called with the lock held.
    private func completeIfReady() {
        guard !completed, readersRemaining == 0, let status else { return }
        completed = true
        let result: Result<LeoProcessResult, Error> = timedOut
            ? .failure(LeoDaemonError.timeout)
            : .success(LeoProcessResult(stdout: stdout, stderr: stderr, status: status))
        continuation.resume(with: result)
    }
}
