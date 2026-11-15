import Foundation
import Testing

@testable import LeoKit

/// B-219 pins: an agent shown as errored while it works fine. The sidebar
/// mirrors the daemon, so the cause is daemon-side. The errored-specific fix
/// is leo #318 (`clearErroredOnSessionStart`); leo #327 lets later hooks from
/// a /clear session through the gate. Both depend on the SessionStart
/// `/api/agent/context` call reaching the daemon; without it every hook from
/// the new session is dropped and no newer revision ever arrives. These pin
/// the app's half of the contract: a newer daemon revision always supersedes
/// a committed `errored`, and the app never hides a daemon-reported `errored`
/// on its own (D-011, principle 2).
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

    @Test func erroredOnRunningRowStaysWithoutNewerRevision() {
        var reducer = live(["x": signal(.errored, 55)])

        // The row is visibly working, but the daemon has not moved past r55:
        // a same-revision and an older `working` signal are both ignored.
        reducer.receive(agent: "x", signal: signal(.working, 55), now: 0)
        reducer.receive(agent: "x", signal: signal(.working, 54), now: 0)
        _ = reducer.tick(now: 60)

        #expect(reducer.nextDeadline == nil)
        #expect(reducer.state(of: "x") == .errored)
        #expect(reducer.badge(for: "x", legacyActivity: .working) == .errored)
    }
}
