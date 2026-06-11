import Testing
import Foundation
@testable import Ghostty

@MainActor
struct LeoAgentStoreTests {
    @Test func refreshPopulatesAgentsAndMarksOnline() async throws {
        let daemon = MockLeoDaemon(agents: [
            Agent(name: "a", template: "coding", repo: "x/a", workspace: "/w", status: .running, startedAt: "t", env: [:])
        ])
        let store = LeoAgentStore(daemon: daemon)
        await store.refresh()
        #expect(store.agents.count == 1)
        #expect(store.connection == .online)
    }

    @Test func refreshFailureMarksOffline() async throws {
        let daemon = MockLeoDaemon()
        await daemon.setNextError(.daemonUnreachable)
        let store = LeoAgentStore(daemon: daemon)
        await store.refresh()
        #expect(store.connection == .offline)
        #expect(store.agents.isEmpty)
    }

    @Test func stopRefreshesAndReflectsNewStatus() async throws {
        let daemon = MockLeoDaemon(agents: [
            Agent(name: "a", template: "coding", repo: "x/a", workspace: "/w", status: .running, startedAt: "t", env: [:])
        ])
        let store = LeoAgentStore(daemon: daemon)
        await store.refresh()
        await store.stop(name: "a")
        #expect(store.agents.first?.status == .stopped)
        #expect(await daemon.stopped == ["a"])
    }
}
