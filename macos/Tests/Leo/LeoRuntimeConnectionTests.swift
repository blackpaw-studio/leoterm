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
