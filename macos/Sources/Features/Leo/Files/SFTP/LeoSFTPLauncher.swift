import Foundation
import OSLog

/// A running SFTP server's stdio: its stdout (`fromServer`) and stdin
/// (`toServer`), plus a way to stop it. The transport owns both handles.
final class LeoSFTPChannel: @unchecked Sendable {
    let fromServer: FileHandle
    let toServer: FileHandle
    private let stop: () -> Void
    private let classifyFailure: (Bool) -> LeoFileAccessError
    private let subsystemRejected: () -> Bool

    init(
        fromServer: FileHandle,
        toServer: FileHandle,
        stop: @escaping () -> Void,
        classifyFailure: @escaping (Bool) -> LeoFileAccessError = { _ in .disconnected },
        subsystemRejected: @escaping () -> Bool = { false }
    ) {
        self.fromServer = fromServer
        self.toServer = toServer
        self.stop = stop
        self.classifyFailure = classifyFailure
        self.subsystemRejected = subsystemRejected
    }

    /// Idempotent.
    func terminate() {
        stop()
    }

    /// Direct/in-memory channels have no child context and stay
    /// `.disconnected`; process channels use bounded exit/stderr context.
    func failure(beforeHandshake: Bool) -> LeoFileAccessError {
        classifyFailure(beforeHandshake)
    }

    var wasSubsystemRejected: Bool { subsystemRejected() }
}

/// Starts an SFTP server process. Injected so tests can run macOS's own
/// `/usr/libexec/sftp-server` (or a scripted fake) directly over pipes.
protocol LeoSFTPLaunching: Sendable {
    /// Throws `.unavailable` if the local process cannot start.
    func launch() throws -> LeoSFTPChannel
    /// A second mux channel only when the first child proves sshd rejected
    /// the SFTP subsystem. Never a direct SSH connection.
    func launchFallback(after channel: LeoSFTPChannel) throws -> LeoSFTPChannel?
}

extension LeoSFTPLaunching {
    func launchFallback(after channel: LeoSFTPChannel) throws -> LeoSFTPChannel? { nil }
}

/// Launches `executable arguments` with piped stdin/stdout. Production runs
/// `/usr/bin/ssh` with `LeoSSHCommand.sftpArguments(controlPath:)`; stderr
/// (ssh's diagnostics) goes to the unified log.
struct LeoSFTPProcessLauncher: LeoSFTPLaunching {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    let executable: URL
    let arguments: [String]
    let fallbackArguments: [String]?

    init(executable: URL, arguments: [String], fallbackArguments: [String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.fallbackArguments = fallbackArguments
    }

    func launch() throws -> LeoSFTPChannel {
        try launch(arguments: arguments)
    }

    func launchFallback(after channel: LeoSFTPChannel) throws -> LeoSFTPChannel? {
        guard channel.wasSubsystemRejected, let fallbackArguments else { return nil }
        return try launch(arguments: fallbackArguments)
    }

    private func launch(arguments: [String]) throws -> LeoSFTPChannel {
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
        let monitor = LeoSFTPProcessMonitor(handle: errors.fileHandleForReading)
        process.terminationHandler = { finished in
            Self.logger.log("sftp exited status=\(finished.terminationStatus) executable=\(executablePath, privacy: .public)")
            monitor.didTerminate(finished)
        }
        do {
            try process.run()
        } catch {
            Self.logger.error("sftp launch failed executable=\(executablePath, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw LeoFileAccessError.unavailable(reason: "the SFTP process couldn’t start")
        }
        monitor.start()
        return LeoSFTPChannel(
            fromServer: output.fileHandleForReading,
            toServer: input.fileHandleForWriting,
            stop: { if process.isRunning { process.terminate() } },
            classifyFailure: { beforeHandshake in
                guard let observation = monitor.observe() else { return .disconnected }
                guard observation.reason != .uncaughtSignal, observation.status != 255 else { return .disconnected }
                // A server may cleanly close an established session without
                // a service failure. Before VERSION, even status 0 means the
                // advertised SFTP service never became available.
                if !beforeHandshake, observation.status == 0, observation.detail.isEmpty {
                    return .disconnected
                }
                if beforeHandshake, observation.status == 127,
                   observation.detail.contains(LeoSSHCommand.missingSFTPServerMarker) {
                    return .unavailable(
                        reason: "no supported SFTP server was found on the host (status 127). Install the host’s OpenSSH server package, then try again"
                    )
                }
                let phase = beforeHandshake ? "exited before starting" : "stopped"
                var reason: LeoFileAccessReason = "the SFTP service \(verbatim: phase) (status \(observation.status))"
                if !observation.detail.isEmpty {
                    reason = reason + ": " + .untrusted(observation.detail)
                }
                return .unavailable(reason: reason)
            },
            subsystemRejected: { monitor.observe()?.isSubsystemRejection == true }
        )
    }
}

/// Drains a child's stderr so it can never fill the pipe and deadlock the
/// handshake, while retaining only a small prefix. The prefix is cleaned
/// before it reaches logs or UI; arguments and environment are never added.
private final class LeoSFTPProcessMonitor: @unchecked Sendable {
    private static let byteLimit = 4 * 1024
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    struct Observation {
        let status: Int32
        let reason: Process.TerminationReason
        let detail: String
        let isSubsystemRejection: Bool
    }

    private let handle: FileHandle
    private let condition = NSCondition()
    private var data = Data()
    private var isTruncated = false
    private var isStderrFinished = false
    private var outcome: (status: Int32, reason: Process.TerminationReason)?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        let reader = Thread { [self] in
            while let chunk = try? handle.read(upToCount: 4 * 1024), !chunk.isEmpty {
                condition.withLock {
                    let remaining = max(0, Self.byteLimit - data.count)
                    if chunk.count > remaining { isTruncated = true }
                    data.append(chunk.prefix(remaining))
                }
            }
            condition.withLock {
                isStderrFinished = true
                condition.broadcast()
            }
        }
        reader.name = "leo-sftp-stderr"
        reader.start()
    }

    func didTerminate(_ process: Process) {
        condition.withLock {
            outcome = (process.terminationStatus, process.terminationReason)
            condition.broadcast()
        }
    }

    func observe() -> Observation? {
        let result: (
            outcome: (status: Int32, reason: Process.TerminationReason),
            data: Data,
            isTruncated: Bool
        )? = condition.withLock {
            let deadline = Date().addingTimeInterval(1)
            while outcome == nil, condition.wait(until: deadline) {}
            guard let outcome else { return nil }
            while !isStderrFinished, condition.wait(until: deadline) {}
            return (outcome, data, isTruncated)
        }
        guard let result else { return nil }
        let text = String(data: result.data, encoding: .utf8) ?? "<\(result.data.count) bytes>"
        let detail = LeoSFTPServerText.sanitized(text)
        if !detail.isEmpty {
            Self.logger.log("sftp stderr: \(detail, privacy: .private)")
        }
        // A mux client never receives the rejection line: the ControlMaster
        // logs it and closes the session, so the client exits 255 with no
        // stderr at all. Every other mux failure (master gone, refused
        // session) explains itself on stderr.
        let isSubsystemRejection = result.outcome.reason == .exit
            && result.outcome.status == 255
            && (result.data.isEmpty
                || LeoSFTPSubsystemRejection.isCanonical(in: result.data, isTruncated: result.isTruncated))
        return Observation(
            status: result.outcome.status,
            reason: result.outcome.reason,
            detail: detail,
            isSubsystemRejection: isSubsystemRejection
        )
    }
}
