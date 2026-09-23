import Foundation
import Testing

@testable import Ghostty

/// Edge cases found before the attention daemon shipped: stale baselines
/// outside recovery, and three daemon
/// semantics (launches report `unknown`, `errored` survives an auto-restart,
/// a fresh `/state` row can briefly lack the field).
struct LeoAttentionEdgeCaseTests {
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

    // MARK: (c) Baseline outside recovery

    @Test func aStaleBaselineOutsideRecoveryDoesNotRegress() {
        var reducer = live(["alpha": signal(.working, 5)])
        reducer.receive(agent: "alpha", signal: signal(.finished, 6), now: 0)
        _ = reducer.tick(now: 0.3)

        // A /state fetch that started before revision 6 lands afterwards.
        reducer.applyBaseline(["alpha": signal(.working, 5)])
        #expect(reducer.state(of: "alpha") == .finished)

        reducer.receive(agent: "alpha", signal: signal(.needsInput, 7), now: 1)
        let transitions = reducer.tick(now: 1.3)

        #expect(transitions.map(\.from) == [.finished])
    }

    @Test func aBaselineOutsideRecoveryKeepsAPendingCandidate() {
        var reducer = live(["alpha": signal(.working, 5)])
        reducer.receive(agent: "alpha", signal: signal(.finished, 6), now: 0)

        reducer.applyBaseline(["alpha": signal(.working, 5)])

        #expect(reducer.tick(now: 0.3).map(\.to) == [.finished])
    }

    // MARK: (d) Launch/resume reports unknown

    @Test func aLaunchReportingUnknownNeverBadgesOrNotifies() {
        var reducer = live()
        reducer.resetAgent("alpha")
        reducer.receive(agent: "alpha", signal: signal(.unknown, 1), now: 0)

        #expect(reducer.badge(for: "alpha", legacyActivity: .working) == nil, "no legacy Working while unknown settles")
        let transitions = reducer.tick(now: 0.3)
        #expect(transitions.map(\.shouldNotify) == [false])
        #expect(reducer.badge(for: "alpha", legacyActivity: .working) == nil)
        #expect(reducer.dockCount(among: ["alpha"]) == 0)
    }

    @Test func resumingAFinishedAgentClearsItToUnknownSilently() {
        var reducer = live(["alpha": signal(.finished, 3)])
        #expect(reducer.dockCount(among: ["alpha"]) == 1)

        reducer.receive(agent: "alpha", signal: signal(.unknown, 4), now: 0)
        let transitions = reducer.tick(now: 0.3)

        #expect(transitions.map(\.shouldNotify) == [false])
        #expect(reducer.badge(for: "alpha", legacyActivity: .working) == nil)
        #expect(reducer.dockCount(among: ["alpha"]) == 0)
    }

    @Test func onlyARealTurnStartShowsWorking() {
        var reducer = live(["alpha": signal(.unknown, 1)])
        #expect(reducer.badge(for: "alpha", legacyActivity: .working) == nil)

        reducer.receive(agent: "alpha", signal: signal(.working, 2), now: 0)
        _ = reducer.tick(now: 0.3)

        #expect(reducer.badge(for: "alpha", legacyActivity: .idle) == .working)
    }

    // MARK: (f) A fresh row briefly without the field

    @Test func aBaselineMissingAFreshAgentsFieldKeepsItsSpawnedAttention() {
        var reducer = live()

        // alpha spawns during a recovery whose /state caught it before its
        // field was set.
        reducer.beginRecovery()
        reducer.resetAgent("alpha")
        reducer.receive(agent: "alpha", signal: signal(.unknown, 1), now: 0)
        reducer.applyBaseline([:])

        #expect(reducer.isSupported("alpha"))
        #expect(reducer.badge(for: "alpha", legacyActivity: .working) == nil)
        reducer.receive(agent: "alpha", signal: signal(.needsInput, 2), now: 1)
        #expect(reducer.tick(now: 1.3).map(\.from) == [.unknown])
    }

    @Test func theNextEventIsAuthoritativeForARowFirstSeenWithoutTheField() {
        var reducer = live(["beta": signal(.working, 1)])
        #expect(!reducer.isSupported("alpha"))

        reducer.receive(agent: "alpha", signal: signal(.unknown, 1), now: 0)
        _ = reducer.tick(now: 0.3)

        #expect(reducer.isSupported("alpha"))
        #expect(reducer.badge(for: "alpha", legacyActivity: .working) == nil)
        #expect(reducer.badge(for: "beta", legacyActivity: .idle) == .working, "one row never changes another's mode")
    }

    @Test func aStaleEntryMissingFromTheReconnectBaselineIsDropped() {
        var reducer = live(["alpha": signal(.finished, 1)])
        reducer.disconnect()

        reducer.applyBaseline([:])

        #expect(!reducer.isSupported("alpha"))
    }
}
