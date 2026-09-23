import Foundation
import Testing

@testable import Ghostty

/// Membership races found in review: an agent recreated during a recovery,
/// and a list fetched before an `agent_spawned`.
struct LeoAttentionMembershipTests {
    private static let host = LeoHostID.remote("mars")

    private func live(_ baseline: [String: LeoAttentionSignal] = [:]) -> LeoAttentionReducer {
        var reducer = LeoAttentionReducer()
        reducer.switchHost(Self.host)
        reducer.applyBaseline(baseline)
        return reducer
    }

    private func signal(_ state: LeoAttentionState, _ revision: Int) -> LeoAttentionSignal {
        LeoAttentionSignal(state: state, revision: revision)
    }

    // MARK: Recreated during a recovery

    @Test func anAgentRecreatedDuringAGapLosesItsOldStateAndContinuesAbove() {
        var reducer = live(["alpha": signal(.needsInput, 5)])

        // SSE gap: alpha is deleted and recreated, its agent_spawned lost;
        // the fresh row has no attention field yet.
        reducer.beginRecovery()
        reducer.applyBaseline([:])

        #expect(reducer.state(of: "alpha") == nil, "the old agent's needs_input must not survive")
        #expect(reducer.dockCount(among: ["alpha"]) == 0)
        reducer.receive(agent: "alpha", signal: signal(.finished, 6), now: 0)
        #expect(reducer.tick(now: 0.3).map(\.to) == [.finished], "the new agent continues above the old one's revisions")
    }

    // MARK: Listed but missing from /state

    @Test func aListedAgentSpawnedJustBeforeAGapStillSignals() {
        var reducer = live()
        reducer.resetAgent("alpha")
        reducer.receive(agent: "alpha", signal: signal(.unknown, 1), now: 0)
        _ = reducer.tick(now: 0.3)

        // The recovery's /state caught alpha before its field was set.
        reducer.beginRecovery()
        reducer.retain(agents: ["alpha"])
        reducer.applyBaseline([:])
        reducer.receive(agent: "alpha", signal: signal(.needsInput, 2), now: 1)
        let transitions = reducer.tick(now: 1.3)

        #expect(transitions.map(\.to) == [.needsInput])
        #expect(transitions.map(\.shouldNotify) == [true])
    }

    // MARK: A list fetched before agent_spawned

    @Test func aListFetchedBeforeASpawnDoesNotDropTheSpawnedAgent() {
        var reducer = live(["alpha": signal(.working, 1)])
        let listStarted = reducer.membershipMark

        reducer.resetAgent("beta")
        reducer.receive(agent: "beta", signal: signal(.unknown, 1), now: 0)
        _ = reducer.tick(now: 0.3)
        reducer.retain(agents: ["alpha"], listedSince: listStarted)

        #expect(reducer.isSupported("beta"))
        #expect(reducer.badge(for: "beta", legacyActivity: .working) == nil, "no invented legacy Working")
    }

    @Test func aListFetchedAfterTheSpawnStillDropsADeletedAgent() {
        var reducer = live()
        reducer.resetAgent("beta")
        reducer.receive(agent: "beta", signal: signal(.unknown, 1), now: 0)
        _ = reducer.tick(now: 0.3)
        let listStarted = reducer.membershipMark

        reducer.retain(agents: [], listedSince: listStarted)

        #expect(!reducer.isSupported("beta"))
    }

}
