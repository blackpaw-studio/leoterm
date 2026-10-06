import Foundation
import OSLog

/// A running SFTP server's stdio: its stdout (`fromServer`) and stdin
/// (`toServer`), plus a way to stop it. The transport owns both handles.
final class LeoSFTPChannel: @unchecked Sendable {
    let fromServer: FileHandle
    let toServer: FileHandle
    private let stop: () -> Void
    private let processFailure: () -> LeoFileAccessError?

    init(
        fromServer: FileHandle,
        toServer: FileHandle,
        stop: @escaping () -> Void,
        processFailure: @escaping () -> LeoFileAccessError? = { nil }
    ) {
        self.fromServer = fromServer
        self.toServer = toServer
        self.stop = stop
        self.processFailure = processFailure
    }

    /// Idempotent.
    func terminate() {
        stop()
    }

    /// Waits for a child that ended before the SFTP handshake and returns a
    /// more precise cause when it was the service, rather than the SSH
    /// connection, that failed. Direct/in-memory channels return nil.
    func startupFailure() -> LeoFileAccessError? {
        processFailure()
    }
}

/// Starts an SFTP server process. Injected so tests can run macOS's own
/// `/usr/libexec/sftp-server` (or a scripted fake) directly over pipes.
protocol LeoSFTPLaunching: Sendable {
    /// Throws `.unavailable` if the local process cannot start.
    func launch() throws -> LeoSFTPChannel
}

/// Launches `executable arguments` with piped stdin/stdout. Production runs
/// `/usr/bin/ssh` with `LeoSSHCommand.sftpArguments(controlPath:)`; stderr
/// (ssh's diagnostics) goes to the unified log.
struct LeoSFTPProcessLauncher: LeoSFTPLaunching {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    let executable: URL
    let arguments: [String]

    func launch() throws -> LeoSFTPChannel {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let executablePath = executable.path
        let state = LeoSFTPProcessState()
        process.terminationHandler = { finished in
            Self.logger.log("sftp exited status=\(finished.terminationStatus) executable=\(executablePath, privacy: .public)")
            state.didTerminate(finished)
        }
        do {
            try process.run()
        } catch {
            Self.logger.error("sftp launch failed executable=\(executablePath, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw LeoFileAccessError.unavailable(reason: "the SFTP process couldn’t start")
        }
        let diagnostics = LeoSFTPProcessDiagnostics(handle: errors.fileHandleForReading)
        diagnostics.start()
        return LeoSFTPChannel(
            fromServer: output.fileHandleForReading,
            toServer: input.fileHandleForWriting,
            stop: { if process.isRunning { process.terminate() } },
            processFailure: {
                guard let outcome = state.waitForExit() else { return nil }
                let detail = diagnostics.waitForText()
                if !detail.isEmpty {
                    Self.logger.log("sftp stderr: \(detail, privacy: .private)")
                }
                guard outcome.status != 0 else { return nil }
                // OpenSSH itself reserves 255 for connection/setup errors.
                // Those mean the master or session was actually lost.
                guard outcome.reason != .uncaughtSignal, outcome.status != 255 else {
                    return .disconnected
                }
                if outcome.status == 127, detail.contains(LeoSSHCommand.missingSFTPServerMarker) {
                    return .unavailable(
                        reason: "no supported SFTP server was found on the host (status 127). Install the host’s OpenSSH server package, then try again"
                    )
                }
                var reason: LeoFileAccessReason = "the SFTP service could not start (status \(outcome.status))"
                if !detail.isEmpty {
                    reason = reason + ": " + .untrusted(detail)
                }
                return .unavailable(reason: reason)
            }
        )
    }
}

/// Drains a child's stderr so it can never fill the pipe and deadlock the
/// handshake, while retaining only a small prefix. The prefix is cleaned
/// before it reaches logs or UI; arguments and environment are never added.
private final class LeoSFTPProcessDiagnostics: @unchecked Sendable {
    private static let byteLimit = 4 * 1024

    private let handle: FileHandle
    private let condition = NSCondition()
    private var data = Data()
    private var isFinished = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        let reader = Thread { [self] in
            while let chunk = try? handle.read(upToCount: 4 * 1024), !chunk.isEmpty {
                condition.withLock {
                    let remaining = max(0, Self.byteLimit - data.count)
                    data.append(chunk.prefix(remaining))
                }
            }
            condition.withLock {
                isFinished = true
                condition.broadcast()
            }
        }
        reader.name = "leo-sftp-stderr"
        reader.start()
    }

    func waitForText() -> String {
        let captured = condition.withLock {
            let deadline = Date().addingTimeInterval(1)
            while !isFinished, condition.wait(until: deadline) {}
            return data
        }
        let text = String(data: captured, encoding: .utf8) ?? "<\(captured.count) bytes>"
        return LeoSFTPServerText.sanitized(text)
    }
}

private final class LeoSFTPProcessState: @unchecked Sendable {
    struct Outcome {
        let status: Int32
        let reason: Process.TerminationReason
    }

    private let condition = NSCondition()
    private var outcome: Outcome?

    func didTerminate(_ process: Process) {
        condition.withLock {
            outcome = Outcome(status: process.terminationStatus, reason: process.terminationReason)
            condition.broadcast()
        }
    }

    /// EOF normally arrives alongside process exit. Bound the exceptional
    /// case where a child closes stdout but keeps running, so one user action
    /// can never wait forever for diagnostic context.
    func waitForExit() -> Outcome? {
        condition.withLock {
            let deadline = Date().addingTimeInterval(1)
            while outcome == nil, condition.wait(until: deadline) {}
            return outcome
        }
    }
}
