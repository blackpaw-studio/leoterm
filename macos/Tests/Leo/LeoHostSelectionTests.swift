import Darwin
import Foundation
import Testing

@testable import Ghostty

/// `LeoHostSelection` owns exactly one app-owned SSH tunnel for the
/// currently selected remote host. Uses the real `fake_ssh.py` fixture
/// (invoked directly via its shebang, so the exact argv `LeoSSHCommand`
/// builds is what actually runs) plus a gate on the injected health-probe
/// transport to exercise generation staleness deterministically.
@Suite(.serialized)
@MainActor struct LeoHostSelectionTests {
    @Test func selectingLocalhostIsImmediatelyConnected() async {
        let selection = makeSelection()
        await selection.start(flavor: .legacy)
        #expect(selection.selected == .local)
        #expect(selection.state == .connected(socketPath: LeoHostSelectionTests.localSocketPath))
    }

    @Test func selectingAConfiguredRemoteHostConnectsWithExpectedSocketPathAndArgv() async throws {
        let argvFile = tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_ARGV_FILE", argvFile)
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_ARGV_FILE", nil) }

        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = makeSelection(hosts: [configuration], transport: AlwaysHealthyTransport())
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))
        let expectedLocalPath = try expectedLocalSocketPath(configuration)
        await awaitCondition(message: "never reached .connected") {
            await (selection.state == .connected(socketPath: expectedLocalPath))
        }

        let expectedArguments = try LeoSSHCommand(configuration: configuration).tunnelArguments(
            localSocketPath: expectedLocalPath, remoteSocketPath: "/remote/leo.sock"
        )
        await awaitCondition { FileManager.default.fileExists(atPath: argvFile) }
        let actualArgv = try String(contentsOfFile: argvFile, encoding: .utf8).components(separatedBy: "\n")
        #expect(actualArgv == expectedArguments)

        selection.shutdown()
    }

    @Test func tildeRemoteSocketPathIsResolvedThroughTheHomeCommand() async throws {
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "~/leo.sock")
        let runner = FakeHomeRunner(stdout: "/home/evan")
        let selection = makeSelection(hosts: [configuration], transport: AlwaysHealthyTransport(), runner: runner)
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))
        let expectedLocalPath = try expectedLocalSocketPath(configuration)
        await awaitCondition(message: "never reached .connected") {
            await (selection.state == .connected(socketPath: expectedLocalPath))
        }

        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls.first?.arguments == (try LeoSSHCommand(configuration: configuration).remoteHomeCommand()))

        selection.shutdown()
    }

    @Test func exitedSSHPublishesFailedWithStderrTailAndHostKeyHint() async {
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", "1")
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_MESSAGE", "Host key verification failed for work.\n")
        defer {
            LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", nil)
            LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_MESSAGE", nil)
        }
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = makeSelection(hosts: [configuration])
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))

        await awaitCondition(message: "never reached .failed") {
            let state = await selection.state
            return isFailed(state)
        }
        guard case .failed(let message, let hint) = selection.state else {
            Issue.record("expected .failed"); return
        }
        #expect(message == "Host key verification failed for work.\n")
        #expect(hint == "Run `ssh evan@work` once in a terminal to accept the host key")
    }

    @Test func exitedSSHPublishesFailedWithPermissionDeniedHint() async {
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", "1")
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_MESSAGE", "Permission denied (publickey).\n")
        defer {
            LeoTunnelTestSupport.setEnvironment("FAKE_SSH_EXIT_IMMEDIATELY", nil)
            LeoTunnelTestSupport.setEnvironment("FAKE_SSH_STDERR_MESSAGE", nil)
        }
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = makeSelection(hosts: [configuration])
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))

        await awaitCondition(message: "never reached .failed") {
            let state = await selection.state
            return isFailed(state)
        }
        guard case .failed(_, let hint) = selection.state else { Issue.record("expected .failed"); return }
        #expect(hint == "ssh needs a key or agent in BatchMode; try `ssh evan@work` in a terminal")
    }

    @Test func switchingHostsOnlyTheLastGenerationPublishesAndTheOldChildIsConfirmedGone() async throws {
        let transport = GatedTransport()
        let a = LeoHostConfiguration(name: "a", sshTarget: "evan@a", remoteSocketPath: "/remote/leo.sock")
        let b = LeoHostConfiguration(name: "b", sshTarget: "evan@b", remoteSocketPath: "/remote/leo.sock")
        let selection = makeSelection(hosts: [a, b], transport: transport)
        await selection.start(flavor: .socketEvents)

        let pidFileA = tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFileA)
        selection.select(.remote("a"))
        await awaitCondition(message: "a never launched") { FileManager.default.fileExists(atPath: pidFileA) }
        let pidA = try readPID(pidFileA)

        let pidFileB = tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFileB)
        selection.select(.remote("b"))
        await awaitCondition(message: "b never launched") { FileManager.default.fileExists(atPath: pidFileB) }
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil)

        // By the time b's process has launched, select(b)'s teardown of a's
        // tunnel -- awaited before b's own connect steps run -- must already
        // have confirmed a's process is gone.
        #expect(Darwin.kill(pidA, 0) == -1 && errno == ESRCH)

        await transport.open()
        let expectedBPath = try expectedLocalSocketPath(b)
        await awaitCondition(message: "b never reached .connected") {
            await (selection.state == .connected(socketPath: expectedBPath))
        }
        #expect(selection.selected == .remote("b"))

        selection.shutdown()
    }

    @Test func retryWhileConnectingReplacesTheInFlightAttempt() async throws {
        let transport = GatedTransport()
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = makeSelection(hosts: [configuration], transport: transport)
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))
        await awaitCondition { await (selection.state == .connecting) }
        selection.retry()
        #expect(selection.state == .connecting)

        await transport.open()
        let expectedPath = try expectedLocalSocketPath(configuration)
        await awaitCondition(message: "never reached .connected after retry") {
            await (selection.state == .connected(socketPath: expectedPath))
        }

        selection.shutdown()
    }

    @Test func tunnelDeathAfterConnectedPublishesFailedWithoutRelaunching() async throws {
        let pidFile = tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile)
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil) }

        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = makeSelection(hosts: [configuration], transport: AlwaysHealthyTransport())
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))

        let expectedPath = try expectedLocalSocketPath(configuration)
        await awaitCondition(message: "never reached .connected") {
            await (selection.state == .connected(socketPath: expectedPath))
        }
        let pid = try await awaitPID(pidFile)
        try FileManager.default.removeItem(atPath: pidFile)

        _ = Darwin.kill(pid, SIGKILL)

        await awaitCondition(message: "never reached .failed after the child died") {
            let state = await selection.state
            return isFailed(state)
        }

        for _ in 0..<20 { await Task.yield() }
        #expect(!FileManager.default.fileExists(atPath: pidFile), "a new child relaunched without an explicit retry")
    }

    @Test func shutdownSynchronouslyTerminatesTheCurrentTunnel() async throws {
        let pidFile = tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile)
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil) }

        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = makeSelection(hosts: [configuration], transport: AlwaysHealthyTransport())
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))

        let expectedPath = try expectedLocalSocketPath(configuration)
        await awaitCondition(message: "never reached .connected") {
            await (selection.state == .connected(socketPath: expectedPath))
        }
        let pid = try await awaitPID(pidFile)

        selection.shutdown()

        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func orphanRecordIsWrittenAfterConnectAndClearedOnExit() async throws {
        let pidFile = tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile)
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil) }

        let suiteDefaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let orphanStore = LeoTunnelOrphanStore(defaults: suiteDefaults)
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let selection = makeSelection(hosts: [configuration], transport: AlwaysHealthyTransport(), defaults: suiteDefaults, orphanStore: orphanStore)
        await selection.start(flavor: .socketEvents)
        selection.select(.remote("work"))

        let expectedPath = try expectedLocalSocketPath(configuration)
        await awaitCondition(message: "never reached .connected") {
            await (selection.state == .connected(socketPath: expectedPath))
        }
        let pid = try await awaitPID(pidFile)
        let record = try #require(orphanStore.current())
        #expect(record.pid == pid)
        #expect(record.socketPath == expectedPath)

        selection.shutdown()

        await awaitCondition(message: "orphan record was never cleared after shutdown") {
            orphanStore.current() == nil
        }
    }

    // MARK: - Helpers

    static let localSocketPath = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath

    private func makeSelection(
        hosts: [LeoHostConfiguration] = [],
        transport: any LeoDaemonTransport = AlwaysHealthyTransport(),
        runner: any LeoProcessRunning = LeoProcessRunner(),
        defaults: UserDefaults? = nil,
        orphanStore: LeoTunnelOrphanStore? = nil
    ) -> LeoHostSelection {
        let defaults = defaults ?? (UserDefaults(suiteName: "LeoHostSelectionTests.\(UUID().uuidString)") ?? .standard)
        if let data = try? JSONEncoder().encode(hosts) { defaults.set(data, forKey: LeoHostStore.key) }
        return LeoHostSelection(
            store: LeoHostStore(defaults: defaults),
            defaults: defaults,
            runner: runner,
            sshExecutable: LeoTunnelTestSupport.fixtureURL(),
            transport: transport,
            orphanStore: orphanStore,
            localSocketPath: Self.localSocketPath
        )
    }

    private func expectedLocalSocketPath(_ configuration: LeoHostConfiguration) throws -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("leoterm", isDirectory: true)
            .appendingPathComponent(configuration.localSocketFileName)
            .path
    }

    private func tempFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("lhs-\(UUID().uuidString.prefix(8))").path
    }

    private func readPID(_ path: String) throws -> Int32 {
        let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(Int32(text))
    }

    /// `AlwaysHealthyTransport` answers `/health` unconditionally, so
    /// `LeoTunnel`'s readiness loop can resolve before the just-forked
    /// `fake_ssh.py` child has actually reached its own pid-file write --
    /// wait for the file itself, not just `.connected`, before reading it.
    private func awaitPID(_ path: String) async throws -> Int32 {
        await awaitCondition(message: "pid file was never written") { FileManager.default.fileExists(atPath: path) }
        return try readPID(path)
    }
}

private func isFailed(_ state: LeoHostConnectionState) -> Bool {
    if case .failed = state { return true }
    return false
}

/// Always answers `/health` with 200 immediately -- used by tests that don't
/// care about probe timing.
private struct AlwaysHealthyTransport: LeoDaemonTransport {
    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        LeoHTTPResponse(status: 200, body: Data())
    }
}

/// Parks every `/health` call until `open()` is called, at which point every
/// pending AND future call resolves successfully. Lets a test force two
/// concurrent connect attempts to race deterministically.
private actor GatedTransport: LeoDaemonTransport {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return LeoHTTPResponse(status: 200, body: Data())
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor FakeHomeRunner: LeoProcessRunning {
    private(set) var calls: [(executable: String, arguments: [String])] = []
    let stdout: String

    init(stdout: String) { self.stdout = stdout }

    func run(executable: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        calls.append((executable, arguments))
        return LeoProcessResult(stdout: Data(stdout.utf8), stderr: Data(), status: 0)
    }
}
