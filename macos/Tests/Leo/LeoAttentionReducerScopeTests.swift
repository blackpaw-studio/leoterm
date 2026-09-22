import Foundation
import Testing

@testable import Ghostty

/// Reducer rules that span a single connection's lifetime: the notification
/// scope of each transition (boot id + agent incarnation), focus surviving a
/// host switch, and the legacy badge staying put while a first signal settles.
struct LeoAttentionReducerScopeTests {
    private static let host = LeoHostID.remote("mars")
    private static let alpha = LeoAgentRow.ID(host: host, name: "alpha")

    private func live(_ baseline: [String: LeoAttentionSignal] = [:]) -> LeoAttentionReducer {
        var reducer = LeoAttentionReducer()
        reducer.switchHost(Self.host)
        reducer.applyBaseline(baseline)
        return reducer
    }

    private func signal(_ state: LeoAttentionState, _ revision: Int) -> LeoAttentionSignal {
        LeoAttentionSignal(state: state, revision: revision)
    }

    // MARK: Notification scope

    @Test func transitionsCarryTheBootIDTheyWereCommittedUnder() {
        var reducer = live()
        _ = reducer.observeBoot("b1")
        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 0)
        #expect(reducer.tick(now: 0.3).map(\.bootID) == ["b1"])

        let restarted = reducer.observeBoot("b2")
        #expect(restarted)
        reducer.applyBaseline([:])
        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 1)
        #expect(reducer.tick(now: 1.3).map(\.bootID) == ["b2"])
    }

    @Test func resettingAnAgentStartsANewIncarnationForItAlone() {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 0)
        reducer.receive(agent: "beta", signal: signal(.finished, 1), now: 0)
        let before = reducer.tick(now: 0.3)

        reducer.resetAgent("alpha")
        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 1)
        reducer.receive(agent: "beta", signal: signal(.needsInput, 2), now: 1)
        let after = reducer.tick(now: 1.3)

        #expect(before.map(\.incarnation) == [0, 0])
        #expect(after.first { $0.id.name == "alpha" }?.incarnation != 0)
        #expect(after.first { $0.id.name == "beta" }?.incarnation == 0)
    }

    // MARK: Focus across a host switch

    @Test func focusSurvivesSwitchingAwayAndBack() {
        var reducer = live()
        reducer.focus(Self.alpha)
        reducer.switchHost(.local)
        reducer.applyBaseline([:])
        reducer.switchHost(Self.host)
        reducer.applyBaseline([:])

        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 0)
        let transitions = reducer.tick(now: 0.3)

        #expect(transitions.map(\.shouldNotify) == [false], "the user is still looking at alpha")
        #expect(reducer.dockCount(among: ["alpha"]) == 0)
    }

    @Test func focusOnAnotherHostStaysInertAfterASwitch() {
        var reducer = live()
        reducer.focus(.init(host: .local, name: "alpha"))
        reducer.switchHost(Self.host)
        reducer.applyBaseline([:])

        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 0)

        #expect(reducer.tick(now: 0.3).map(\.shouldNotify) == [true])
    }

    // MARK: Legacy badge while the first signal settles

    @Test func legacyWorkingBadgeStaysUntilTheFirstCandidateCommits() {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.working, 1), now: 0)

        #expect(reducer.badge(for: "alpha", legacyActivity: .working) == .working)
        #expect(reducer.badge(for: "alpha", legacyActivity: .idle) == nil)

        _ = reducer.tick(now: 0.3)
        #expect(reducer.badge(for: "alpha", legacyActivity: .idle) == .working)
    }
}
