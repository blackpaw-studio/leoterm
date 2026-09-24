import Foundation
import Testing

@testable import Ghostty

/// B-019: `LeoRuntime.focusedAgentChanged` reaches the feed only through
/// `focusedAgentRelay` (B-016), so a burst of focus changes lands in order.
@MainActor struct LeoRuntimeFocusRelayTests {
    /// The relay's sink sees every change, in order, once the relay has
    /// drained. A change that goes around the relay never reaches the
    /// sink, so this does not depend on timing.
    @Test func focusChangesReachTheFeedOnlyThroughTheOrderedRelay() async throws {
        let defaults = LeoInMemoryDefaults()
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let delivered = Delivered()
        let runtime = LeoRuntime(
            daemon: EmptyDaemon(), cli: LeoCLI(), activitySource: activitySource, defaults: defaults,
            focusedAgentSink: { await delivered.append($0) }
        )
        defer { runtime.shutdown() }
        let alpha = LeoAgentIdentity(host: .local, name: "alpha")
        let beta = LeoAgentIdentity(host: .local, name: "beta")
        let sent = [alpha, nil, beta, nil, alpha]

        for identity in sent { runtime.focusedAgentChanged(identity) }
        await runtime.focusedAgentRelay.finish()

        let expected = sent.map { $0.map { LeoAgentRow.ID(host: $0.host, name: $0.name) } }
        #expect(await delivered.values == expected, "focus reaches the feed only through the ordered relay")
    }
}

private actor Delivered {
    private(set) var values: [LeoAgentRow.ID?] = []
    func append(_ value: LeoAgentRow.ID?) { values.append(value) }
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
