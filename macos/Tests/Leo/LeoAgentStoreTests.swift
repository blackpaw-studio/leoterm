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

    @Test func refreshSortsAgentsByNameForStableOrder() async throws {
        // The daemon returns the roster in an unstable order; the store must
        // sort by name so the sidebar doesn't reshuffle on every poll.
        let daemon = MockLeoDaemon(agents: [
            Agent(name: "zebra", template: "coding", repo: "x/z", workspace: "/w", status: .running, startedAt: "t", env: [:]),
            Agent(name: "alpha", template: "coding", repo: "x/a", workspace: "/w", status: .running, startedAt: "t", env: [:]),
            Agent(name: "mango", template: "coding", repo: "x/m", workspace: "/w", status: .running, startedAt: "t", env: [:])
        ])
        let store = LeoAgentStore(daemon: daemon)
        await store.refresh()
        #expect(store.agents.map(\.name) == ["alpha", "mango", "zebra"])
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
