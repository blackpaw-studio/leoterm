import Foundation
import Testing

@testable import Ghostty

/// Shared helpers for `LeoHostSelectionTests`/`LeoHostSelectionRaceTests`.
enum LeoHostSelectionTestSupport {
    static let localSocketPath = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath

    /// Tests never touch the real `~/.leo/state/leoterm` or per-user cache
    /// directory -- that's production data. They share this directory
    /// instead, injected through `LeoHostSelection`'s socket-directory
    /// parameters; sharing it across one process's tests is safe because
    /// `LeoControlSocketDirectory.prepare` is idempotent and every host
    /// configuration has its own id. It is unique to this test process
    /// (B-032): a fixed path is shared by every run and parallel worker, so
    /// a later run meets stale sockets and one worker's
    /// `LeoTunnel.removeStaleSocket()` can unlink another's live socket.
    /// Reserved atomically (`socketDirectoryReservation`), and removed by
    /// `LeoRealCacheDirectoryGuard` when the bundle finishes.
    /// Tests that care about the directory's own permissions use their own
    /// (`makeIsolatedSocketDirectory`). `/tmp` (not `$TMPDIR`) and only 8
    /// hex characters deliberately: macOS's per-process `$TMPDIR`
    /// (`/var/folders/<random>/T/`) is long enough on its own to push a
    /// socket path past the AF_UNIX limit `LeoSSHCommand.tunnelArguments`
    /// enforces -- the same overflow that motivated moving the production
    /// directory.
    static let localSocketDirectory: URL = {
        do {
            return try socketDirectoryReservation.reserve()
        } catch {
            preconditionFailure("could not reserve the test socket directory: \(error)")
        }
    }()

    /// 27 bytes, like `makeIsolatedSocketDirectory`'s paths.
    static let socketDirectoryReservation = LeoReservedTestDirectory(template: "/tmp/leoterm-tests-XXXXXXXX")

    @MainActor static func makeSelection(
        hosts: [LeoHostConfiguration] = [],
        transport: any LeoDaemonTransport = LeoAlwaysHealthyTransport(),
        runner: any LeoProcessRunning = LeoProcessRunner(),
        defaults: UserDefaults? = nil,
        orphanStore: LeoTunnelOrphanStore? = nil,
        localSocketDirectory: URL = localSocketDirectory,
        sshExecutable: URL = LeoTunnelTestSupport.fixtureURL(),
        controlSocketInstance: String = LeoHostSelection.defaultControlSocketInstance,
        controlSocketDirectory: URL? = nil,
        controlSocketOwner: uid_t = geteuid()
    ) -> LeoHostSelection {
        let defaults = defaults ?? (UserDefaults(suiteName: "LeoHostSelectionTests.\(UUID().uuidString)") ?? .standard)
        if let data = try? JSONEncoder().encode(hosts) { defaults.set(data, forKey: LeoHostStore.key) }
        return LeoHostSelection(
            store: LeoHostStore(defaults: defaults),
            defaults: defaults,
            runner: runner,
            sshExecutable: sshExecutable,
            transport: transport,
            orphanStore: orphanStore,
            localSocketPath: localSocketPath,
            legacySocketDirectory: localSocketDirectory,
            // Holds the forwarded and control sockets; the legacy directory
            // unless a test says otherwise: never the real per-user cache
            // directory.
            controlSocketDirectory: controlSocketDirectory ?? localSocketDirectory,
            controlSocketInstance: controlSocketInstance,
            controlSocketOwner: controlSocketOwner
        )
    }

    static func expectedLocalSocketPath(
        _ configuration: LeoHostConfiguration,
        in directory: URL = localSocketDirectory,
        instance: String = LeoHostSelection.defaultControlSocketInstance
    ) -> String {
        directory.appendingPathComponent(configuration.tunnelSocketFileName(instance: instance)).path
    }

    /// Where the tunnel's ControlMaster socket lives -- and therefore the
    /// ControlPath every SFTP session must multiplex over.
    static func expectedControlPath(
        _ configuration: LeoHostConfiguration,
        in directory: URL = localSocketDirectory,
        instance: String = LeoHostSelection.defaultControlSocketInstance
    ) -> String {
        directory.appendingPathComponent(configuration.controlSocketFileName(instance: instance)).path
    }

    /// A per-test `fake_ssh.py` wrapper that records its argv to `argvFile`
    /// -- without touching the process-wide environment other suites'
    /// tunnels also read.
    static func argvRecordingSSH(in directory: URL, argvFile: String) throws -> URL {
        let script = directory.appendingPathComponent("ssh")
        let body = "#!/bin/sh\nFAKE_SSH_ARGV_FILE='\(argvFile)' exec '\(LeoTunnelTestSupport.fixtureURL().path)' \"$@\"\n"
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    static func recordedArgv(_ argvFile: String) async throws -> [String] {
        await awaitCondition { FileManager.default.fileExists(atPath: argvFile) }
        return try String(contentsOfFile: argvFile, encoding: .utf8).components(separatedBy: "\n")
    }

    /// A directory unique to one test, for tests that assert on the
    /// directory's own permissions (as opposed to just the socket path) --
    /// never pre-created, so the caller controls its starting state. Lives
    /// under `/tmp` (not `$TMPDIR`) and uses only the first 8 hex
    /// characters of the UUID, for the same AF_UNIX-path-length reason as
    /// `localSocketDirectory` above.
    static func makeIsolatedSocketDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/leoterm-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    static func tempFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("lhs-\(UUID().uuidString.prefix(8))").path
    }

    static func readPID(_ path: String) throws -> Int32 {
        let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(Int32(text))
    }

    /// `LeoAlwaysHealthyTransport` answers `/health` unconditionally, so
    /// `LeoTunnel`'s readiness loop can resolve before the just-forked
    /// `fake_ssh.py` child has actually reached its own pid-file write --
    /// wait for the file itself, not just `.connected`, before reading it.
    /// Existence implies complete contents only because `fake_ssh.py`
    /// publishes the file with an atomic rename.
    static func awaitPID(_ path: String, timeout: TimeInterval = 5) async throws -> Int32 {
        await awaitCondition(timeout: timeout, message: "pid file was never written") { FileManager.default.fileExists(atPath: path) }
        return try readPID(path)
    }

    @MainActor static func awaitConnected(_ selection: LeoHostSelection, _ path: String) async {
        await awaitCondition(message: "never reached .connected(\(path))") {
            await selection.state == .connected(socketPath: path)
        }
    }

    @MainActor static func awaitFailed(_ selection: LeoHostSelection) async {
        await awaitCondition(message: "never reached .failed") {
            let state = await selection.state
            return isFailed(state)
        }
    }

    static func isFailed(_ state: LeoHostConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

/// Always answers `/health` with 200 immediately -- used by tests that don't
/// care about probe timing.
struct LeoAlwaysHealthyTransport: LeoDaemonTransport {
    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        LeoHTTPResponse(status: 200, body: Data())
    }
}

/// Parks every `/health` call until `open()` is called, at which point every
/// pending AND future call resolves successfully. Cancellation-aware: a
/// probe `Task` cancelled while parked (e.g. because `LeoTunnel.start()` was
/// interrupted by `terminateAndWait()`) resumes with `CancellationError`
/// instead of leaking a continuation forever.
actor LeoGatedTransport: LeoDaemonTransport {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        if !isOpen {
            let id = UUID()
            try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { waiters[id] = $0 }
                },
                onCancel: { Task { await self.cancelWaiter(id) } }
            )
        }
        return LeoHTTPResponse(status: 200, body: Data())
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func open() {
        isOpen = true
        waiters.values.forEach { $0.resume() }
        waiters = [:]
    }
}

actor LeoFakeHomeRunner: LeoProcessRunning {
    private(set) var calls: [(executable: String, arguments: [String])] = []
    let stdout: String

    init(stdout: String) { self.stdout = stdout }

    func run(executable: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        calls.append((executable, arguments))
        return LeoProcessResult(stdout: Data(stdout.utf8), stderr: Data(), status: 0)
    }
}

extension LeoHostSelection {
    /// A selection on its own throwaway defaults suite (or `defaults`), for
    /// tests that need one to inject: its sockets live in the shared test
    /// directory, never the real per-user cache directory (B-032).
    @MainActor static func isolatedForTesting(defaults: UserDefaults? = nil) -> LeoHostSelection {
        let defaults = defaults ?? {
            let suite = "LeoHostSelectionTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }()
        let directory = LeoHostSelectionTestSupport.localSocketDirectory
        return LeoHostSelection(
            store: LeoHostStore(defaults: defaults),
            defaults: defaults,
            orphanStore: LeoTunnelOrphanStore(defaults: defaults, legacySocketDirectory: directory),
            legacySocketDirectory: directory,
            controlSocketDirectory: directory
        )
    }
}
