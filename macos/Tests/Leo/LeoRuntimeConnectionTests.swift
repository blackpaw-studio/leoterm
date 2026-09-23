import Darwin
import Foundation
import Testing

@testable import Ghostty

/// Per-connection wiring: `LeoRuntime` binds the feed and agent actions to
/// whichever daemon `LeoHostSelection`'s current connection resolves to.
@MainActor struct LeoRuntimeConnectionTests {
    @Test func startupRoutesListAndActionRequestsToTheSelectedConnectionsDaemon() async throws {
        let daemon = RuntimeTestDaemon()
        let defaults = UserDefaults(suiteName: "LeoRuntimeConnectionTests.\(UUID().uuidString)") ?? .standard
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(daemon: daemon, cli: LeoCLI(), activitySource: activitySource, defaults: defaults)
        _ = runtime.makeWindowSession()

        runtime.start()

        await awaitCondition(message: "the feed never listed against the selected connection's daemon") {
            await daemon.listCallCount >= 1
        }

        runtime.actions.start(.init(host: .local, name: "alpha", template: nil, status: .running, activity: .unknown, actionDetail: nil))
        await awaitCondition(message: "the action never reached the selected connection's daemon") {
            await daemon.startCalls == ["alpha"]
        }

        runtime.shutdown()
    }

    /// `LeoRuntime.shutdown()` is the AppDelegate quit hook's entry point --
    /// it must synchronously engage `LeoHostSelection.shutdown()` (which
    /// itself synchronously terminates the current tunnel, see
    /// `LeoHostSelectionRaceTests`). Verified here via the `isShutDown`
    /// gate's observable effect: a `select()` after `shutdown()` must be a
    /// no-op.
    /// One tunnel per host: agent actions use the runtime's own selection,
    /// never a second one that could start a sibling tunnel.
    @Test func agentActionsShareTheRuntimesSingleHostSelection() {
        let defaults = UserDefaults(suiteName: "LeoRuntimeConnectionTests.\(UUID().uuidString)") ?? .standard
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(daemon: RuntimeTestDaemon(), cli: LeoCLI(), activitySource: activitySource, defaults: defaults)

        #expect(runtime.actions.hostSelection === runtime.hostSelection)
        runtime.shutdown()
    }

    @Test func shutdownSynchronouslyEngagesHostSelectionShutdown() throws {
        let daemon = RuntimeTestDaemon()
        let defaults = UserDefaults(suiteName: "LeoRuntimeConnectionTests.\(UUID().uuidString)") ?? .standard
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(daemon: daemon, cli: LeoCLI(), activitySource: activitySource, defaults: defaults)

        runtime.shutdown()
        let stateAfterShutdown = runtime.hostSelection.state

        runtime.hostSelection.select(.remote("anything"))

        #expect(runtime.hostSelection.state == stateAfterShutdown, "select() after shutdown() must be a no-op")
    }

    /// `applyConnected`'s flavor-detection `await` is the one place a stale
    /// async build could install over a newer state. Gates that SECOND
    /// `/health` call (the tunnel's own readiness probe is call #1, which
    /// always succeeds immediately) so the test can force the exact
    /// interleaving: the tunnel connects, THEN dies (publishing `.failed`
    /// for the SAME generation) WHILE flavor detection is still parked, and
    /// only then is the gate released.
    @Test func failureDuringGatedFlavorDetectionStaysFailedAndIsNeverOverwritten() async throws {
        let pidFile = LeoHostSelectionTestSupport.tempFile()
        LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", pidFile)
        defer { LeoTunnelTestSupport.setEnvironment("FAKE_SSH_PID_FILE", nil) }

        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let defaults = UserDefaults(suiteName: "LeoRuntimeConnectionTests.\(UUID().uuidString)") ?? .standard
        if let data = try? JSONEncoder().encode([configuration]) { defaults.set(data, forKey: LeoHostStore.key) }
        let transport = SequenceGatedHealthTransport()
        let daemon = RuntimeTestDaemon()
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(
            daemon: daemon, cli: LeoCLI(), activitySource: activitySource, defaults: defaults,
            hostConnectionTransport: transport,
            hostSelectionSSHExecutable: LeoTunnelTestSupport.fixtureURL()
        )

        await runtime.hostSelection.start(flavor: .socketEvents)
        runtime.hostSelection.select(.remote("work"))
        let pid = try await LeoHostSelectionTestSupport.awaitPID(pidFile)
        await awaitCondition(message: "flavor detection never reached the gate") { await transport.callCount >= 2 }

        _ = Darwin.kill(pid, SIGKILL)
        await awaitCondition(message: "never reached .failed after the tunnel died") {
            let state = await runtime.hostSelection.state
            if case .failed = state { return true }
            return false
        }

        await transport.open()
        for _ in 0..<50 { await Task.yield() }

        guard case .failed = runtime.hostSelection.state else {
            Issue.record("expected .failed to persist, got \(runtime.hostSelection.state)")
            return
        }
        if case .failed = runtime.model.snapshot.connectivity {
        } else {
            Issue.record("stale flavor-detection result overwrote the feed's failed connectivity: \(runtime.model.snapshot.connectivity)")
        }

        runtime.shutdown()
    }
}

/// Answers the FIRST `/health` call (the tunnel's own readiness probe)
/// immediately; every call after that (flavor detection) parks until
/// `open()` is called.
private actor SequenceGatedHealthTransport: LeoDaemonTransport {
    private(set) var callCount = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        callCount += 1
        if callCount == 1 {
            return LeoHTTPResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
        }
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return LeoHTTPResponse(status: 200, body: Data(#"{"ok":true,"data":{"version":"0.29.0"}}"#.utf8))
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor RuntimeTestDaemon: LeoDaemonClient {
    private(set) var listCallCount = 0
    private(set) var startCalls: [String] = []

    func listAgents() async throws -> [LeoAgent] { listCallCount += 1; return [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { fatalError() }
    func start(_ name: String) async throws { startCalls.append(name) }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { fatalError() }
    func restart(_ name: String) async throws -> LeoAgent { fatalError() }
    func reset(_ name: String) async throws { fatalError() }
    func setTemplate(_ name: String, template: String) async throws { fatalError() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { fatalError() }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { fatalError() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { fatalError() }
    func logs(_ name: String, lines: Int?) async throws -> String { fatalError() }
}
