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

    @Test func isRefreshingIsFalseBeforeAndAfterRefresh() async throws {
        let daemon = MockLeoDaemon()
        let store = LeoAgentStore(daemon: daemon)
        #expect(store.isRefreshing == false)
        await store.refresh()
        #expect(store.isRefreshing == false)
    }

    @Test func refreshTemplatesRecordsErrorInsteadOfSwallowingIt() async throws {
        // A missing `leo` binary (or any listTemplates failure) must surface
        // via `lastError` rather than disappear via `try?`.
        let daemon = MockLeoDaemon()
        await daemon.setNextError(.decode(detail: "leo: command not found"))
        let store = LeoAgentStore(daemon: daemon)
        await store.refreshTemplates()
        #expect(store.lastError == "Could not read the daemon response: leo: command not found")
        #expect(store.templates.isEmpty)
    }

    @Test func refreshTemplatesPopulatesTemplatesOnSuccess() async throws {
        let daemon = MockLeoDaemon(templates: [Template(name: "coding", workspace: "/w")])
        let store = LeoAgentStore(daemon: daemon)
        await store.refreshTemplates()
        #expect(store.templates.map(\.name) == ["coding"])
        #expect(store.lastError == nil)
    }

    @Test func pruneRemovesAgentThenRefreshes() async throws {
        let daemon = MockLeoDaemon(agents: [
            Agent(name: "a", template: "coding", repo: "x/a", workspace: "/w", status: .stopped, startedAt: "t", env: [:])
        ])
        let store = LeoAgentStore(daemon: daemon)
        await store.refresh()
        await store.prune(name: "a")
        #expect(store.agents.isEmpty)
    }

    @Test func pruneFailureSurvivesFollowUpRefresh() async throws {
        // The daemon's DELETE fails with a structured code (e.g.
        // `agent_still_running`), but the follow-up `refresh()` (a plain
        // `listAgents`) succeeds. The action's error must still reach the UI
        // — `refresh()` succeeding must not silently clear it.
        let daemon = MockLeoDaemon(agents: [
            Agent(name: "a", template: "coding", repo: "x/a", workspace: "/w", status: .running, startedAt: "t", env: [:])
        ])
        await daemon.setNextError(.daemon(message: "agent is running", code: "agent_still_running"))
        let store = LeoAgentStore(daemon: daemon)
        await store.prune(name: "a")
        #expect(store.lastError == "Leo daemon error: agent is running")
        #expect(store.connection == .online) // the follow-up refresh did succeed
    }

    @Test func stopFailureSurvivesFollowUpRefresh() async throws {
        let daemon = MockLeoDaemon(agents: [
            Agent(name: "a", template: "coding", repo: "x/a", workspace: "/w", status: .running, startedAt: "t", env: [:])
        ])
        await daemon.setNextError(.daemon(message: "no such agent", code: "not_found"))
        let store = LeoAgentStore(daemon: daemon)
        await store.stop(name: "a")
        #expect(store.lastError == "Leo daemon error: no such agent")
        #expect(store.connection == .online)
    }

    @Test func pruneErrorCarriesStructuredCodeFromDaemon() async throws {
        // Direct-daemon check that the mock actually throws the code (kept
        // alongside the store-level assertions above).
        let daemon = MockLeoDaemon(agents: [
            Agent(name: "a", template: "coding", repo: "x/a", workspace: "/w", status: .running, startedAt: "t", env: [:])
        ])
        await daemon.setNextError(.daemon(message: "agent is running", code: "agent_still_running"))
        await #expect(throws: LeoError.daemon(message: "agent is running", code: "agent_still_running")) {
            try await daemon.prune(name: "a")
        }
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
