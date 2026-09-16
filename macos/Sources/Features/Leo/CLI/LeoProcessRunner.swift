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
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do { try process.run() } catch { throw LeoDaemonError.transport("Cannot run \(executable): \(error.localizedDescription)") }
            let output = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()
            output.enter()
            DispatchQueue.global().async { stdoutData = stdout.fileHandleForReading.readDataToEndOfFile(); output.leave() }
            output.enter()
            DispatchQueue.global().async { stderrData = stderr.fileHandleForReading.readDataToEndOfFile(); output.leave() }
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            let deadline = DispatchTime.now() + timeout
            guard exited.wait(timeout: deadline) == .success else {
                process.terminate()
                throw LeoDaemonError.timeout
            }
            _ = output.wait(timeout: deadline)
            return LeoProcessResult(stdout: stdoutData, stderr: stderrData, status: process.terminationStatus)
        }.value
    }
}
