import Foundation
import Testing

@testable import Ghostty

/// Opt-in end-to-end run of the shared file-access contract suites through
/// real `ssh`: with `LEO_SSH_E2E_HOST=localhost` set, both contract suites
/// gain an `sshEndToEnd` backend case that multiplexes SFTP over a
/// tunnel-style ControlMaster started from the app's own argv builder.
/// Unset, the case does not exist and nothing touches ssh.
///
/// Only `localhost` is accepted: the contract suites arrange and inspect
/// their fixtures with local file APIs, which only see the remote side
/// when the remote side is this machine.
enum LeoSSHEndToEnd {
    static let hostVariable = "LEO_SSH_E2E_HOST"
    static let allowedHost = "localhost"

    static var host: String? {
        guard let value = ProcessInfo.processInfo.environment[hostVariable], !value.isEmpty else { return nil }
        return value
    }

    static var isEnabled: Bool { host != nil }

    /// The connection of the suite currently running, set by `trait`.
    @TaskLocal static var current: LeoSSHEndToEndConnection?

    static var trait: LeoSSHEndToEndTrait { LeoSSHEndToEndTrait() }
}

/// Starts one master (and remote temp directory) around a whole suite, and
/// always tears both down afterwards.
struct LeoSSHEndToEndTrait: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable @concurrent () async throws -> Void) async throws {
        guard let host = LeoSSHEndToEnd.host else {
            try await function()
            return
        }
        guard host == LeoSSHEndToEnd.allowedHost else {
            Issue.record("\(LeoSSHEndToEnd.hostVariable) must be \(LeoSSHEndToEnd.allowedHost), not \(host)")
            return
        }
        let connection = try await LeoSSHEndToEndConnection.start(host: host)
        do {
            try await LeoSSHEndToEnd.$current.withValue(connection) { try await function() }
        } catch {
            await connection.stop()
            throw error
        }
        await connection.stop()
    }
}

enum LeoSSHEndToEndError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case commandFailed([String], String)

    var description: String {
        switch self {
        case let .connectionFailed(detail): "ControlMaster did not come up: \(detail)"
        case let .commandFailed(command, detail): "ssh \(command.joined(separator: " ")) failed: \(detail)"
        }
    }
}

/// A `ssh -N` ControlMaster built by `LeoSSHCommand.tunnelArguments` -- the
/// exact argv the app's tunnel runs -- plus a `mktemp -d` directory on the
/// host created over it. File access goes through
/// `LeoSSHCommand.sftpArguments`, as in the app.
final class LeoSSHEndToEndConnection: @unchecked Sendable {
    static let ssh = URL(fileURLWithPath: "/usr/bin/ssh")
    /// Parallel contract tests each open an SFTP session over the one
    /// master; sshd's default MaxSessions is 10.
    private static let maxSessions = 4

    let host: String
    let remoteDirectory: String
    private let command: LeoSSHCommand
    private let localDirectory: URL
    private let controlPath: String
    private let process: Process
    private let permits = LeoAsyncPermits(LeoSSHEndToEndConnection.maxSessions)

    private init(host: String, remoteDirectory: String, command: LeoSSHCommand, localDirectory: URL, controlPath: String, process: Process) {
        self.host = host
        self.remoteDirectory = remoteDirectory
        self.command = command
        self.localDirectory = localDirectory
        self.controlPath = controlPath
        self.process = process
    }

    static func start(host: String) async throws -> LeoSSHEndToEndConnection {
        let localDirectory = URL(fileURLWithPath: "/tmp/leoterm-sftp-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let controlPath = localDirectory.appendingPathComponent("cm").path
        let command = LeoSSHCommand(configuration: LeoHostConfiguration(name: "e2e", sshTarget: host))
        let process = Process()
        process.executableURL = ssh
        process.arguments = try command.tunnelArguments(
            localSocketPath: localDirectory.appendingPathComponent("t.sock").path,
            remoteSocketPath: "/nonexistent/leo-e2e.sock",
            controlPath: controlPath
        )
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        do {
            try await waitUntilListening(controlPath, process: process, errors: errors)
            let remoteDirectory = try await makeRemoteDirectory(controlPath: controlPath, host: host)
            let connection = LeoSSHEndToEndConnection(
                host: host, remoteDirectory: remoteDirectory, command: command,
                localDirectory: localDirectory, controlPath: controlPath, process: process
            )
            do {
                try await connection.checkSFTP()
            } catch {
                await connection.stop()
                throw error
            }
            return connection
        } catch {
            terminate(process)
            try? FileManager.default.removeItem(at: localDirectory)
            throw error
        }
    }

    func makeAccess() throws -> any LeoFileAccess {
        let arguments = try command.sftpArguments(controlPath: controlPath)
        return LeoFileAccessor.sftp(launcher: LeoSFTPProcessLauncher(executable: Self.ssh, arguments: arguments))
    }

    /// One SFTP round trip before any contract test runs, so a host without
    /// an installed SFTP server fails the suite once, clearly, instead of
    /// every case repeating the same error.
    private func checkSFTP() async throws {
        let access = try makeAccess()
        do {
            _ = try await access.stat(remoteDirectory)
            await access.close()
        } catch {
            await access.close()
            throw LeoSSHEndToEndError.connectionFailed(
                "SFTP over the master failed (\(error)); check that \(host) has an OpenSSH sftp-server installed"
            )
        }
    }

    func withSession(_ body: () async throws -> Void) async throws {
        await permits.acquire()
        do {
            try await body()
        } catch {
            await permits.release()
            throw error
        }
        await permits.release()
    }

    /// Removes the remote temp directory over the master, then the master
    /// and its local directory. Best effort: a failure is recorded, never
    /// thrown past the suite.
    func stop() async {
        do {
            _ = try await Self.run(["rm", "-rf", "--", remoteDirectory], controlPath: controlPath, host: host)
        } catch {
            Issue.record("could not remove \(remoteDirectory): \(error)")
        }
        Self.terminate(process)
        try? FileManager.default.removeItem(at: localDirectory)
    }

    // MARK: - Helpers

    private static func waitUntilListening(_ controlPath: String, process: Process, errors: Pipe) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if LeoControlSocket.inspect(controlPath) == .live { return }
            guard process.isRunning else {
                let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw LeoSSHEndToEndError.connectionFailed("ssh exited \(process.terminationStatus): \(detail)")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw LeoSSHEndToEndError.connectionFailed("no listener at \(controlPath) after 15s")
    }

    private static func makeRemoteDirectory(controlPath: String, host: String) async throws -> String {
        let output = try await run(["mktemp", "-d"], controlPath: controlPath, host: host)
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path.count > 1, !path.contains("\n"), !path.contains(" ") else {
            throw LeoSSHEndToEndError.commandFailed(["mktemp", "-d"], "unexpected output \(output)")
        }
        return path
    }

    /// Runs `remote` on the host as a mux client of the master only (a gone
    /// master fails rather than dialling a fresh connection).
    private static func run(_ remote: [String], controlPath: String, host: String) async throws -> String {
        let arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath)",
            "-o", "ProxyCommand=/usr/bin/false", host, try remote.map(leoShellQuote).joined(separator: " ")
        ]
        let result = try await LeoProcessRunner().run(executable: ssh.path, arguments: arguments, timeout: 15)
        guard result.status == 0 else {
            throw LeoSSHEndToEndError.commandFailed(remote, String(data: result.stderr, encoding: .utf8) ?? "status \(result.status)")
        }
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }

    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

/// A counting semaphore for async code.
actor LeoAsyncPermits {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) {
        available = count
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
