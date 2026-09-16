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

    private func completeIfReady() {
        guard !completed, readersRemaining == 0, let status else { return }
        completed = true
        let result: Result<LeoProcessResult, Error> = timedOut
            ? .failure(LeoDaemonError.timeout)
            : .success(LeoProcessResult(stdout: stdout, stderr: stderr, status: status))
        continuation.resume(with: result)
    }
}
