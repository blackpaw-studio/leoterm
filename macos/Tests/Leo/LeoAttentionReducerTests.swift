import Foundation
import Testing

@testable import Ghostty

/// Scripted traces against `LeoAttentionReducer` with an injected clock
/// (plain `TimeInterval`s), one test per transition in the attention spec.
struct LeoAttentionReducerTests {
    private static let host = LeoHostID.remote("mars")
    private static let alpha = LeoAgentRow.ID(host: host, name: "alpha")
    private static let beta = LeoAgentRow.ID(host: host, name: "beta")

    /// A connected reducer with an empty baseline already applied.
    private func live(_ baseline: [String: LeoAttentionSignal] = [:]) -> LeoAttentionReducer {
        var reducer = LeoAttentionReducer()
        reducer.switchHost(Self.host)
        reducer.applyBaseline(baseline)
        return reducer
    }

    private func signal(_ state: LeoAttentionState, _ revision: Int) -> LeoAttentionSignal {
        LeoAttentionSignal(state: state, revision: revision)
    }

    // MARK: Commit stability

    @Test func liveSignalCommitsOnlyAfter300msStability() {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.needsInput, 1), now: 10)
        #expect(reducer.state(of: "alpha") == nil)
        #expect(reducer.nextDeadline == 10.3)
        #expect(reducer.tick(now: 10.299).isEmpty)
        #expect(reducer.state(of: "alpha") == nil)

        let transitions = reducer.tick(now: 10.3)

        #expect(transitions == [.init(id: Self.alpha, from: nil, to: .needsInput, revision: 1, shouldNotify: true)])
        #expect(reducer.state(of: "alpha") == .needsInput)
        #expect(reducer.nextDeadline == nil)
    }

    @Test func sameStateRepeatDoesNotExtendTheWindow() {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 0)
        reducer.receive(agent: "alpha", signal: signal(.finished, 2), now: 0.2)
        #expect(reducer.nextDeadline == 0.3)

        let transitions = reducer.tick(now: 0.3)

        #expect(transitions.map(\.revision) == [2])
        #expect(reducer.state(of: "alpha") == .finished)
    }

    @Test func differentCandidateReplacesAndRestartsTheWindow() {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.needsInput, 1), now: 0)
        reducer.receive(agent: "alpha", signal: signal(.working, 2), now: 0.2)
        #expect(reducer.tick(now: 0.3).isEmpty)
        #expect(reducer.nextDeadline == 0.5)

        let transitions = reducer.tick(now: 0.5)

        #expect(transitions == [.init(id: Self.alpha, from: nil, to: .working, revision: 2, shouldNotify: false)])
    }

    @Test func flickerBackToCommittedStateCancelsTheCandidate() {
        var reducer = live(["alpha": signal(.working, 1)])
        reducer.receive(agent: "alpha", signal: signal(.finished, 2), now: 0)
        reducer.receive(agent: "alpha", signal: signal(.working, 3), now: 0.1)

        #expect(reducer.nextDeadline == nil)
        #expect(reducer.tick(now: 5).isEmpty)
        #expect(reducer.state(of: "alpha") == .working)
    }

    @Test func repeatedWorkingAtANewerRevisionEmitsNothing() {
        var reducer = live(["alpha": signal(.working, 4)])
        reducer.receive(agent: "alpha", signal: signal(.working, 5), now: 0)

        #expect(reducer.nextDeadline == nil)
        #expect(reducer.tick(now: 1).isEmpty)
    }

    // MARK: Same-state repeats at a newer revision (daemon spec: a new event)

    @Test func repeatedAttentionStateAtANewerRevisionIsANewEvent() {
        var reducer = live(["alpha": signal(.finished, 4)])
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 0)

        #expect(reducer.nextDeadline == 0.3)
        #expect(reducer.tick(now: 0.3) == [.init(id: Self.alpha, from: .finished, to: .finished, revision: 5, shouldNotify: true)])
    }

    @Test func repeatReArmsAnAcknowledgedDockContribution() {
        var reducer = live(["alpha": signal(.needsInput, 1)])
        reducer.focus(Self.alpha)
        reducer.focus(nil)
        #expect(reducer.dockCount(among: ["alpha"]) == 0)

        reducer.receive(agent: "alpha", signal: signal(.needsInput, 2), now: 0)
        _ = reducer.tick(now: 0.3)

        #expect(reducer.dockCount(among: ["alpha"]) == 1)
    }

    @Test func repeatWhileFocusedIsSuppressedAndStaysAcknowledged() {
        var reducer = live(["alpha": signal(.finished, 1)])
        reducer.focus(Self.alpha)
        reducer.receive(agent: "alpha", signal: signal(.finished, 2), now: 0)

        #expect(reducer.tick(now: 0.3).map(\.shouldNotify) == [false])
        #expect(reducer.dockCount(among: ["alpha"]) == 0)
    }

    @Test func repeatDuringAPendingRepeatDoesNotDelayCommit() {
        var reducer = live(["alpha": signal(.finished, 1)])
        reducer.receive(agent: "alpha", signal: signal(.finished, 2), now: 0)
        reducer.receive(agent: "alpha", signal: signal(.finished, 3), now: 0.2)

        #expect(reducer.nextDeadline == 0.3)
        #expect(reducer.tick(now: 0.3).map(\.revision) == [3])
    }

    @Test func quickTurnThroughWorkingBackToFinishedIsANewEvent() {
        var reducer = live(["alpha": signal(.finished, 5)])
        reducer.focus(Self.alpha)
        reducer.focus(nil)
        reducer.receive(agent: "alpha", signal: signal(.working, 6), now: 0)
        reducer.receive(agent: "alpha", signal: signal(.finished, 7), now: 0.1)

        #expect(reducer.tick(now: 0.4) == [.init(id: Self.alpha, from: .finished, to: .finished, revision: 7, shouldNotify: true)])
        #expect(reducer.dockCount(among: ["alpha"]) == 1)
    }

    @Test func baselineAtANewerRevisionReArmsSilently() {
        var reducer = live(["alpha": signal(.finished, 1)])
        reducer.focus(Self.alpha)
        reducer.focus(nil)
        reducer.beginRecovery()
        reducer.applyBaseline(["alpha": signal(.finished, 2)])

        #expect(reducer.dockCount(among: ["alpha"]) == 1)
        #expect(reducer.tick(now: 10).isEmpty)
    }

    // MARK: Daemon restarts (hello boot_id)

    @Test func firstBootIDAndTheSameBootIDAreNotRestarts() {
        var reducer = live(["alpha": signal(.finished, 3)])
        reducer.focus(Self.alpha)
        reducer.focus(nil)

        let first = reducer.observeBoot("b1")
        let same = reducer.observeBoot("b1")
        let absent = reducer.observeBoot(nil)
        #expect(!first && !same && !absent)
        reducer.beginRecovery()
        reducer.applyBaseline(["alpha": signal(.finished, 3)])

        #expect(reducer.dockCount(among: ["alpha"]) == 0, "normal reconnect keeps the acknowledgement")
    }

    @Test func changedBootIDDiscardsRevisionsAndAcknowledgements() {
        var reducer = live(["alpha": signal(.finished, 3)])
        _ = reducer.observeBoot("b1")
        reducer.focus(Self.alpha)
        reducer.focus(nil)
        reducer.receive(agent: "beta", signal: signal(.working, 9), now: 0)

        let restarted = reducer.observeBoot("b2")
        #expect(restarted)
        #expect(reducer.nextDeadline == nil)
        #expect(reducer.state(of: "alpha") == nil)
        reducer.receive(agent: "beta", signal: signal(.finished, 1), now: 0)
        reducer.applyBaseline(["alpha": signal(.finished, 3)])

        #expect(reducer.dockCount(among: ["alpha", "beta"]) == 2, "same revision in a new lifetime is not the acknowledged event")
        #expect(reducer.tick(now: 10).isEmpty, "restart baselines are silent")
    }

    @Test func hostSwitchForgetsTheBootID() {
        var reducer = live()
        _ = reducer.observeBoot("b1")
        reducer.switchHost(.local)
        let restarted = reducer.observeBoot("b2")

        #expect(!restarted)
    }

    @Test func transitionsReportThePreviouslyCommittedState() {
        var reducer = live(["alpha": signal(.working, 1)])
        reducer.receive(agent: "alpha", signal: signal(.finished, 2), now: 0)

        #expect(reducer.tick(now: 0.3) == [.init(id: Self.alpha, from: .working, to: .finished, revision: 2, shouldNotify: true)])
    }

    @Test func candidatesForSeveralAgentsCommitIndependently() {
        var reducer = live()
        reducer.receive(agent: "beta", signal: signal(.finished, 1), now: 0)
        reducer.receive(agent: "alpha", signal: signal(.needsInput, 1), now: 0.1)
        #expect(reducer.tick(now: 0.3).map(\.id) == [Self.beta])
        #expect(reducer.nextDeadline == 0.4)
        #expect(reducer.tick(now: 0.4).map(\.id) == [Self.alpha])
    }

    // MARK: Revision ordering

    @Test func duplicateRevisionIsIgnored() {
        var reducer = live(["alpha": signal(.working, 3)])
        reducer.receive(agent: "alpha", signal: signal(.finished, 3), now: 0)

        #expect(reducer.nextDeadline == nil)
        #expect(reducer.state(of: "alpha") == .working)
    }

    @Test func olderRevisionIsIgnored() {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 0)
        reducer.receive(agent: "alpha", signal: signal(.working, 4), now: 0.1)
        _ = reducer.tick(now: 0.3)

        #expect(reducer.state(of: "alpha") == .finished)
    }

    @Test func explicitUnknownClearsTheBadge() {
        var reducer = live(["alpha": signal(.needsInput, 1)])
        reducer.receive(agent: "alpha", signal: signal(.unknown, 2), now: 0)
        let transitions = reducer.tick(now: 0.3)

        #expect(transitions.map(\.shouldNotify) == [false])
        #expect(reducer.state(of: "alpha") == .unknown)
        #expect(reducer.badge(for: "alpha", legacyActivity: .working) == nil)
        #expect(!reducer.needsAttention("alpha"))
    }

    @Test func spawnResetsRevisionTrackingForARecreatedName() {
        var reducer = live(["alpha": signal(.finished, 9)])
        reducer.resetAgent("alpha")
        reducer.receive(agent: "alpha", signal: signal(.working, 1), now: 0)
        _ = reducer.tick(now: 0.3)

        #expect(reducer.state(of: "alpha") == .working)
    }

    // MARK: Baselines

    @Test func baselineCommitsSilentlyWithoutTransitionsOrDeadlines() {
        var reducer = LeoAttentionReducer()
        reducer.switchHost(Self.host)
        reducer.applyBaseline(["alpha": signal(.needsInput, 2), "beta": signal(.finished, 7)])

        #expect(reducer.nextDeadline == nil)
        #expect(reducer.tick(now: 100).isEmpty)
        #expect(reducer.state(of: "alpha") == .needsInput)
        #expect(reducer.state(of: "beta") == .finished)
    }

    @Test func baselineReplacesStateEvenAtALowerRevision() {
        // A restarted daemon starts revisions over; the baseline is authoritative.
        var reducer = live(["alpha": signal(.finished, 40)])
        reducer.beginRecovery()
        reducer.applyBaseline(["alpha": signal(.working, 1)])

        #expect(reducer.state(of: "alpha") == .working)
    }

    @Test func baselineDropsAgentsItNoLongerReports() {
        var reducer = live(["alpha": signal(.finished, 1)])
        reducer.beginRecovery()
        reducer.applyBaseline([:])

        #expect(reducer.state(of: "alpha") == nil)
        #expect(!reducer.isSupported("alpha"))
    }

    @Test func recoveryCancelsCandidates() {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 0)
        reducer.beginRecovery()

        #expect(reducer.nextDeadline == nil)
        #expect(reducer.tick(now: 1).isEmpty)
    }

    @Test func eventsBufferedDuringRecoveryMergeByRevisionWithoutNotifying() {
        var reducer = live()
        reducer.beginRecovery()
        reducer.receive(agent: "alpha", signal: signal(.finished, 6), now: 0)
        reducer.receive(agent: "beta", signal: signal(.working, 2), now: 0)
        reducer.receive(agent: "gamma", signal: signal(.needsInput, 1), now: 0)
        reducer.applyBaseline(["alpha": signal(.working, 5), "beta": signal(.needsInput, 3)])

        #expect(reducer.nextDeadline == nil)
        #expect(reducer.tick(now: 10).isEmpty)
        #expect(reducer.state(of: "alpha") == .finished, "buffered rev 6 beats baseline rev 5")
        #expect(reducer.state(of: "beta") == .needsInput, "baseline rev 3 beats buffered rev 2")
        #expect(reducer.state(of: "gamma") == .needsInput, "an agent newer than the baseline survives")
    }

    @Test func liveEventsAfterTheBaselineUseTheBaselineRevision() {
        var reducer = live(["alpha": signal(.working, 5)])
        reducer.receive(agent: "alpha", signal: signal(.finished, 5), now: 0)
        #expect(reducer.nextDeadline == nil)
        reducer.receive(agent: "alpha", signal: signal(.finished, 6), now: 0)
        #expect(reducer.tick(now: 0.3).map(\.to) == [.finished])
    }

    // MARK: Host switch and disconnect

    @Test func hostSwitchClearsEverything() {
        var reducer = live(["alpha": signal(.needsInput, 1)])
        reducer.receive(agent: "beta", signal: signal(.finished, 1), now: 0)
        reducer.switchHost(.local)

        #expect(reducer.host == .local)
        #expect(reducer.state(of: "alpha") == nil)
        #expect(reducer.nextDeadline == nil)
        #expect(reducer.tick(now: 1).isEmpty)
        #expect(reducer.dockCount(among: ["alpha", "beta"]) == 0)
    }

    @Test func disconnectMarksStatesStaleAndExcludesThemUntilResync() {
        var reducer = live(["alpha": signal(.needsInput, 1)])
        reducer.disconnect()

        #expect(reducer.isStale("alpha"))
        #expect(!reducer.needsAttention("alpha"))
        #expect(reducer.dockCount(among: ["alpha"]) == 0)
        #expect(reducer.badge(for: "alpha", legacyActivity: .working) == nil)

        reducer.beginRecovery()
        reducer.applyBaseline(["alpha": signal(.needsInput, 1)])

        #expect(!reducer.isStale("alpha"))
        #expect(reducer.dockCount(among: ["alpha"]) == 1)
    }

    @Test func disconnectCancelsCandidates() {
        var reducer = live()
        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 0)
        reducer.disconnect()

        #expect(reducer.nextDeadline == nil)
    }

    // MARK: Legacy fallback

    @Test func legacyAgentShowsWorkingOnlyFromActivity() {
        let reducer = live()

        #expect(!reducer.isSupported("alpha"))
        #expect(reducer.badge(for: "alpha", legacyActivity: .working) == .working)
        #expect(reducer.badge(for: "alpha", legacyActivity: .idle) == nil)
        #expect(reducer.badge(for: "alpha", legacyActivity: .unknown) == nil)
        #expect(!reducer.needsAttention("alpha"))
    }

    @Test func semanticStateWinsOverLegacyActivity() {
        let reducer = live(["alpha": signal(.finished, 1), "beta": signal(.working, 1)])

        #expect(reducer.badge(for: "alpha", legacyActivity: .working) == .finished)
        #expect(reducer.badge(for: "beta", legacyActivity: .idle) == .working, "idle samples never overwrite")
    }

    @Test func pendingCandidateKeepsShowingTheCommittedBadge() {
        var reducer = live(["alpha": signal(.working, 1)])
        reducer.receive(agent: "alpha", signal: signal(.needsInput, 2), now: 0)

        #expect(reducer.badge(for: "alpha", legacyActivity: .idle) == .working)
    }

    // MARK: Focus: Dock acknowledgement and notification suppression

    @Test func dockCountsAgentsNeedingAttention() {
        let reducer = live([
            "a": signal(.needsInput, 1), "b": signal(.finished, 1), "c": signal(.errored, 1),
            "d": signal(.working, 1), "e": signal(.unknown, 1)
        ])

        #expect(reducer.dockCount(among: ["a", "b", "c", "d", "e", "legacy"]) == 3)
        #expect(reducer.dockCount(among: ["a"]) == 1, "only agents present in the list count")
    }

    @Test func focusingAnAgentAcknowledgesItsDockContributionButKeepsTheBadge() {
        var reducer = live(["alpha": signal(.finished, 1), "beta": signal(.needsInput, 1)])
        reducer.focus(Self.alpha)

        #expect(reducer.dockCount(among: ["alpha", "beta"]) == 1)
        #expect(reducer.badge(for: "alpha", legacyActivity: .idle) == .finished)
        #expect(reducer.needsAttention("alpha"))

        reducer.focus(nil)
        #expect(reducer.dockCount(among: ["alpha", "beta"]) == 1, "acknowledgement outlives focus")
    }

    @Test func newRevisionAfterAcknowledgementCountsAgain() {
        var reducer = live(["alpha": signal(.finished, 1)])
        reducer.focus(Self.alpha)
        reducer.focus(nil)
        reducer.receive(agent: "alpha", signal: signal(.working, 2), now: 0)
        _ = reducer.tick(now: 0.3)
        reducer.receive(agent: "alpha", signal: signal(.needsInput, 3), now: 1)
        _ = reducer.tick(now: 1.3)

        #expect(reducer.dockCount(among: ["alpha"]) == 1)
    }

    @Test func focusedAgentTransitionIsSuppressedAndAcknowledged() {
        var reducer = live(["alpha": signal(.working, 1)])
        reducer.focus(Self.alpha)
        reducer.receive(agent: "alpha", signal: signal(.finished, 2), now: 0)

        #expect(reducer.tick(now: 0.3).map(\.shouldNotify) == [false])
        #expect(reducer.dockCount(among: ["alpha"]) == 0)

        reducer.focus(nil)
        #expect(reducer.dockCount(among: ["alpha"]) == 0, "suppressed transitions are consumed, not deferred")
    }

    @Test func focusOnAnotherHostIsIgnored() {
        var reducer = live(["alpha": signal(.finished, 1)])
        reducer.focus(LeoAgentRow.ID(host: .local, name: "alpha"))

        #expect(reducer.dockCount(among: ["alpha"]) == 1)
    }

    @Test func acknowledgementSurvivesAnIdenticalBaseline() {
        var reducer = live(["alpha": signal(.finished, 1)])
        reducer.focus(Self.alpha)
        reducer.focus(nil)
        reducer.beginRecovery()
        reducer.applyBaseline(["alpha": signal(.finished, 1)])

        #expect(reducer.dockCount(among: ["alpha"]) == 0)
    }

    @Test func onlyNeedsInputAndFinishedNotify() {
        var reducer = live()
        reducer.receive(agent: "a", signal: signal(.needsInput, 1), now: 0)
        reducer.receive(agent: "b", signal: signal(.finished, 1), now: 0)
        reducer.receive(agent: "c", signal: signal(.errored, 1), now: 0)
        reducer.receive(agent: "d", signal: signal(.working, 1), now: 0)

        let notifying = reducer.tick(now: 0.3).filter(\.shouldNotify).map(\.id.name)

        #expect(notifying == ["a", "b"])
    }

    @Test func eventsBeforeTheFirstBaselineAreSilent() {
        var reducer = LeoAttentionReducer()
        reducer.switchHost(Self.host)
        reducer.receive(agent: "alpha", signal: signal(.finished, 1), now: 0)

        #expect(reducer.nextDeadline == nil)
        reducer.applyBaseline([:])
        #expect(reducer.tick(now: 1).isEmpty)
        #expect(reducer.state(of: "alpha") == .finished)
    }

    // MARK: Navigation membership and pruning

    @Test func needingAttentionListsNonStaleAgentsInTheGivenOrder() {
        let reducer = live(["b": signal(.finished, 1), "a": signal(.needsInput, 1), "c": signal(.working, 1)])

        #expect(reducer.needingAttention(among: ["c", "b", "a"]) == ["b", "a"])
    }

    @Test func retainPrunesAgentsMissingFromTheList() {
        var reducer = live(["alpha": signal(.finished, 1), "beta": signal(.finished, 1)])
        reducer.receive(agent: "beta", signal: signal(.working, 2), now: 0)
        reducer.retain(agents: ["alpha"])

        #expect(reducer.state(of: "beta") == nil)
        #expect(reducer.nextDeadline == nil)
        #expect(reducer.state(of: "alpha") == .finished)
    }
}
