import Foundation
import OSLog

/// A running SFTP server's stdio: its stdout (`fromServer`) and stdin
/// (`toServer`), plus a way to stop it. The transport owns both handles.
final class LeoSFTPChannel: @unchecked Sendable {
    let fromServer: FileHandle
    let toServer: FileHandle
    private let stop: () -> Void

    init(fromServer: FileHandle, toServer: FileHandle, stop: @escaping () -> Void) {
        self.fromServer = fromServer
        self.toServer = toServer
        self.stop = stop
    }

    /// Idempotent.
    func terminate() {
        stop()
    }
}

/// Starts an SFTP server process. Injected so tests can run macOS's own
/// `/usr/libexec/sftp-server` (or a scripted fake) directly over pipes.
protocol LeoSFTPLaunching: Sendable {
    /// Throws `LeoFileAccessError.disconnected` if the process cannot start.
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
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            Self.logger.log("sftp stderr: \(text, privacy: .public)")
        }
        let executablePath = executable.path
        process.terminationHandler = { finished in
            Self.logger.log("sftp exited status=\(finished.terminationStatus) executable=\(executablePath, privacy: .public)")
        }
        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            Self.logger.error("sftp launch failed executable=\(executablePath, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw LeoFileAccessError.disconnected
        }
        return LeoSFTPChannel(fromServer: output.fileHandleForReading, toServer: input.fileHandleForWriting) {
            if process.isRunning { process.terminate() }
        }
    }
}
