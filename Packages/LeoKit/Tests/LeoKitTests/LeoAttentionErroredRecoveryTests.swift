import Foundation
import Testing

@testable import LeoKit

/// B-219 pins: an agent shown as errored while it works fine. The cause was
/// daemon-side (hooks after a /clear were dropped, so no newer revision ever
/// arrived; fixed in leo PR #327). These pin the app's half of the contract:
/// a newer daemon signal always supersedes a committed `errored`, and the
/// app never hides a daemon-reported `errored` on its own (D-011, principle 2).
struct LeoAttentionErroredRecoveryTests {
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

    @Test func erroredBaselineIsSupersededByNewerLiveSignal() {
        var reducer = live(["x": signal(.errored, 55)])
        #expect(reducer.badge(for: "x", legacyActivity: .working) == .errored)

        reducer.receive(agent: "x", signal: signal(.working, 56), now: 0)
        _ = reducer.tick(now: 0.3)

        #expect(reducer.badge(for: "x", legacyActivity: .working) == .working)
        #expect(!reducer.needsAttention("x"))
        #expect(reducer.dockCount(among: ["x"]) == 0)

        // The 30 s poll baseline repeats the same working state and keeps it.
        reducer.applyBaseline(["x": signal(.working, 56)])
        #expect(reducer.badge(for: "x", legacyActivity: .working) == .working)
    }

    @Test func erroredBaselineIsSupersededByNewerBaseline() {
        var reducer = live(["x": signal(.errored, 55)])

        reducer.applyBaseline(["x": signal(.finished, 60)])

        #expect(reducer.badge(for: "x", legacyActivity: .idle) == .finished)
    }

    @Test func erroredOnRunningRowStaysWithoutNewerSignal() {
        var reducer = live(["x": signal(.errored, 55)])

        // Same-revision polls and ticks with the row visibly working change nothing.
        reducer.applyBaseline(["x": signal(.errored, 55)])
        _ = reducer.tick(now: 60)

        #expect(reducer.badge(for: "x", legacyActivity: .working) == .errored)
        #expect(reducer.state(of: "x") == .errored)
    }
}
