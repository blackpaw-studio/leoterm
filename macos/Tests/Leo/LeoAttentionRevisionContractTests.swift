import Foundation
import Testing

@testable import Ghostty

/// The daemon's revision contract: the counter is per agent name per boot,
/// survives delete and recreate, and a rename bumps it past both names'
/// counters, so `(boot, name, revision)` is unique. A revision at or below
/// the last seen for a name in the same boot is a duplicate; a recreated or
/// renamed agent simply continues at higher revisions.
@MainActor struct LeoAttentionRevisionContractTests {
    private static let host = LeoHostID.remote("mars")

    private func live(_ baseline: [String: LeoAttentionSignal] = [:]) -> LeoAttentionReducer {
        var reducer = LeoAttentionReducer()
        reducer.switchHost(Self.host)
        _ = reducer.observeBoot("b1")
        reducer.applyBaseline(baseline)
        return reducer
    }

    private func signal(_ state: LeoAttentionState, _ revision: Int) -> LeoAttentionSignal {
        LeoAttentionSignal(state: state, revision: revision)
    }

    private func controller() async -> (LeoAttentionController, ContractNotificationCenter) {
        let center = ContractNotificationCenter()
        let defaults = LeoInMemoryDefaults()
        let controller = LeoAttentionController(
            center: center, defaults: defaults, currentHost: { Self.host }, showDeniedInstructions: {}
        )
        await controller.enable()
        return (controller, center)
    }

    // MARK: 1. Recreated during a gap

    @Test func aRecreatedAgentFirstHeardFromDuringRecoveryNotifies() async {
        var reducer = live()
        let (controller, center) = await controller()
        reducer.receive(agent: "alpha", signal: signal(.needsInput, 5), now: 0)
        await controller.handle(reducer.tick(now: 0.3))

        // SSE gap: alpha is deleted and recreated, its agent_spawned lost.
        // Its first signal arrives while recovering; its /state row has no
        // field yet.
        reducer.beginRecovery()
        reducer.receive(agent: "alpha", signal: signal(.working, 7), now: 1)
        reducer.retain(agents: ["alpha"])
        reducer.applyBaseline([:])
        #expect(reducer.state(of: "alpha") == .working)

        reducer.receive(agent: "alpha", signal: signal(.needsInput, 8), now: 2)
        await controller.handle(reducer.tick(now: 2.3))
        reducer.receive(agent: "alpha", signal: signal(.finished, 9), now: 3)
        await controller.handle(reducer.tick(now: 3.3))

        #expect(center.posted.map(\.body) == ["Needs your input", "Needs your input", "Finished"])
    }

    // MARK: 2. Re-added at the same revision

    @Test func anAgentReAddedByABaselineAtTheSameRevisionKeepsItsAcknowledgement() {
        var reducer = live(["alpha": signal(.needsInput, 5)])
        reducer.focus(.init(host: Self.host, name: "alpha"))
        reducer.focus(nil)
        #expect(reducer.dockCount(among: ["alpha"]) == 0)

        // One recovery's /state can't read alpha's field; the next can.
        reducer.beginRecovery()
        reducer.applyBaseline([:])
        reducer.beginRecovery()
        reducer.applyBaseline(["alpha": signal(.needsInput, 5)])

        #expect(reducer.state(of: "alpha") == .needsInput)
        #expect(reducer.dockCount(among: ["alpha"]) == 0, "the same revision was already acknowledged")
    }

    // MARK: 3. Re-sent revisions

    @Test func aReSentRevisionIsNeverRenotifiedEvenAcrossARecovery() {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 0)
        #expect(reducer.tick(now: 0.3).map(\.shouldNotify) == [true])

        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 1)
        #expect(reducer.tick(now: 1.3).isEmpty)

        reducer.beginRecovery()
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 2)
        reducer.applyBaseline(["alpha": signal(.finished, 5)])
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 3)
        #expect(reducer.tick(now: 3.3).isEmpty)

        // A recovery whose /state lacks alpha drops its display state, not
        // its revision floor.
        reducer.beginRecovery()
        reducer.retain(agents: ["alpha"])
        reducer.applyBaseline([:])
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 4)
        #expect(reducer.tick(now: 4.3).isEmpty)
        #expect(reducer.nextDeadline == nil)
    }

    // MARK: 4. Rename

    @Test func aRenameContinuesWithoutDuplicateOrLostNotifications() async {
        var reducer = live(["alpha": signal(.working, 4)])
        let (controller, center) = await controller()
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 0)
        await controller.handle(reducer.tick(now: 0.3))

        // alpha -> beta: beta continues past both names' counters.
        reducer.retain(agents: ["beta"])
        reducer.receive(agent: "beta", signal: signal(.needsInput, 6), now: 1)
        await controller.handle(reducer.tick(now: 1.3))
        reducer.receive(agent: "beta", signal: signal(.needsInput, 6), now: 2)
        await controller.handle(reducer.tick(now: 2.3))

        // beta -> alpha: a late re-send of alpha's old revision is a
        // duplicate; the renamed agent continues above it.
        reducer.retain(agents: ["alpha"])
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 3)
        await controller.handle(reducer.tick(now: 3.3))
        reducer.receive(agent: "alpha", signal: signal(.finished, 7), now: 4)
        await controller.handle(reducer.tick(now: 4.3))

        #expect(center.posted.map(\.title) == ["alpha · mars", "beta · mars", "alpha · mars"])
        #expect(Set(center.posted.map(\.identifier)).count == 3)
        #expect(reducer.state(of: "beta") == nil, "a renamed-away name keeps no display state")
    }
}

@MainActor private final class ContractNotificationCenter: LeoNotificationPosting {
    private(set) var posted: [LeoAttentionNotification] = []
    func requestAlertAuthorization() async -> Bool { true }
    func post(_ notification: LeoAttentionNotification) async { posted.append(notification) }
}
