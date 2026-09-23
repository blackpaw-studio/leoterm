import Foundation
import Testing

@testable import Ghostty

/// B-019: `LeoRuntime.focusedAgentChanged` reaches the feed only through
/// `focusedAgentRelay` (B-016), so a burst of focus changes lands in order.
@MainActor struct LeoRuntimeFocusRelayTests {
    @Test func focusChangesReachTheFeedOnlyThroughTheOrderedRelay() async throws {
        let defaults = try #require(UserDefaults(suiteName: "LeoRuntimeFocusRelayTests.\(UUID().uuidString)"))
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(daemon: EmptyDaemon(), cli: LeoCLI(), activitySource: activitySource, defaults: defaults)
        defer { runtime.shutdown() }
        await runtime.feed.start()
        let alpha = LeoAgentIdentity(host: .local, name: "alpha")
        let beta = LeoAgentIdentity(host: .local, name: "beta")

        for identity in [alpha, nil, beta, nil, alpha] { runtime.focusedAgentChanged(identity) }
        await runtime.focusedAgentRelay.finish()
        #expect(await runtime.feed.attention.focusedID == .init(host: .local, name: "alpha"), "the feed ends on the last change")

        // A finished relay drops what it is sent, so a change that still
        // reaches the feed went around it.
        runtime.focusedAgentChanged(beta)
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(await runtime.feed.attention.focusedID == .init(host: .local, name: "alpha"), "focus bypassed the ordered relay")
        await runtime.feed.stop()
    }
}

private struct EmptyDaemon: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func start(_ name: String) async throws { throw LeoDaemonError.transport("unused") }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { throw LeoDaemonError.transport("unused") }
    func restart(_ name: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func reset(_ name: String) async throws { throw LeoDaemonError.transport("unused") }
    func setTemplate(_ name: String, template: String) async throws { throw LeoDaemonError.transport("unused") }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { throw LeoDaemonError.transport("unused") }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { throw LeoDaemonError.transport("unused") }
    func logs(_ name: String, lines: Int?) async throws -> String { throw LeoDaemonError.transport("unused") }
}
