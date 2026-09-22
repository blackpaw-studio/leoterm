import Foundation
import Testing

@testable import Ghostty

/// Membership races found in review: an agent recreated during a recovery,
/// a list fetched before an `agent_spawned`, and tombstones on a host whose
/// agent names churn.
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

    @Test func anAgentRecreatedDuringAGapLosesItsOldStateAndRevisionFloor() {
        var reducer = live(["alpha": signal(.needsInput, 5)])

        // SSE gap: alpha is deleted and recreated, its agent_spawned lost;
        // the fresh row has no attention field yet.
        reducer.beginRecovery()
        reducer.applyBaseline([:])

        #expect(reducer.state(of: "alpha") == nil, "the old agent's needs_input must not survive")
        #expect(reducer.dockCount(among: ["alpha"]) == 0)
        reducer.receive(agent: "alpha", signal: signal(.finished, 2), now: 0)
        let transitions = reducer.tick(now: 0.3)
        #expect(transitions.map(\.to) == [.finished], "the new agent's low revisions apply")
        #expect(transitions.first?.incarnation != 0, "and never share the old agent's incarnation")
    }

    // MARK: Listed but missing from /state

    @Test func aListedAgentWithUnreadableAttentionIsNotRenotifiedAfterARecovery() throws {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 0)
        let finished = try #require(reducer.tick(now: 0.3).first)
        let posted = try #require(LeoAttentionNotification(finished))

        for recovery in 1...2 {
            // alpha's /state field decodes to nil; the list still has it.
            reducer.beginRecovery()
            reducer.retain(agents: ["alpha"])
            reducer.applyBaseline([:])
            #expect(reducer.state(of: "alpha") == nil, "a state the daemon didn't report isn't kept")

            // The daemon re-sends alpha's latest revision.
            let now = Double(recovery)
            reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: now)
            let resent = reducer.tick(now: now + 0.3).compactMap(LeoAttentionNotification.init)
            #expect(resent.map(\.identifier) == [posted.identifier], "the same post, deduped -- never a new one")
        }
    }

    @Test func aListedAgentSpawnedJustBeforeAGapKeepsItsIncarnation() throws {
        var reducer = live()
        reducer.resetAgent("alpha")
        reducer.receive(agent: "alpha", signal: signal(.unknown, 1), now: 0)
        let spawned = try #require(reducer.tick(now: 0.3).first?.incarnation)

        // The recovery's /state caught alpha before its field was set.
        reducer.beginRecovery()
        reducer.retain(agents: ["alpha"])
        reducer.applyBaseline([:])
        reducer.receive(agent: "alpha", signal: signal(.needsInput, 2), now: 1)
        let transitions = reducer.tick(now: 1.3)

        #expect(transitions.map(\.to) == [.needsInput])
        #expect(transitions.first?.incarnation == spawned)
    }

    @Test func anAgentLeavingTheListAfterItsFieldWentMissingIsTombstoned() throws {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 0)
        let first = try #require(reducer.tick(now: 0.3).first)
        reducer.disconnect()
        reducer.retain(agents: ["alpha"])
        reducer.applyBaseline([:])

        // alpha is deleted, then recreated and reaches revision 5 again.
        reducer.retain(agents: [])
        reducer.retain(agents: ["alpha"])
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 1)
        let transitions = reducer.tick(now: 1.3)

        #expect(transitions.map(\.to) == [.finished])
        #expect(transitions.first?.incarnation != first.incarnation, "a new agent's post is never deduped against the old one's")
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

    // MARK: Bounded tombstones

    @Test func tombstonesStayBoundedWhileAgentNamesChurn() {
        var reducer = live()
        for index in 0..<(LeoAttentionReducer.tombstoneLimit * 3) {
            let name = "scratch-\(index)"
            reducer.receive(agent: name, signal: signal(.working, 1), now: 0)
            reducer.retain(agents: [])
        }

        #expect(reducer.tombstoneCount == LeoAttentionReducer.tombstoneLimit)
    }

    @Test func aLiveAgentAwaitingItsFirstSignalIsNeverTrimmedAsATombstone() throws {
        var reducer = live()
        reducer.resetAgent("alpha")
        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 0)
        let first = try #require(reducer.tick(now: 0.3).first?.incarnation)

        // alpha is recreated; before it signals, many other agents churn.
        reducer.resetAgent("alpha")
        for index in 0...LeoAttentionReducer.tombstoneLimit {
            reducer.receive(agent: "scratch-\(index)", signal: signal(.working, 1), now: 1)
            reducer.retain(agents: ["alpha"])
        }
        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 2)
        let transitions = reducer.tick(now: 2.3)

        #expect(transitions.map(\.to) == [.finished])
        #expect(transitions.first?.incarnation != first, "never the earlier alpha's notification id")
        #expect(transitions.first?.incarnation != 0)
    }

    @Test func theNewestTombstoneSurvivesTheBound() {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 0)
        let before = reducer.tick(now: 0.3)
        for index in 0..<(LeoAttentionReducer.tombstoneLimit * 2) {
            reducer.receive(agent: "scratch-\(index)", signal: signal(.working, 1), now: 1)
        }
        reducer.retain(agents: ["alpha"])
        reducer.retain(agents: [])

        reducer.retain(agents: ["alpha"])
        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 2)
        let after = reducer.tick(now: 2.3)

        #expect(reducer.tombstoneCount <= LeoAttentionReducer.tombstoneLimit)
        #expect(after.first?.incarnation != before.first?.incarnation)
    }
}
