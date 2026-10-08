import Foundation
import Testing

@testable import Ghostty

struct LeoDispatchTreeTests {
    private func dispatch(
        _ id: String, caller: String? = "alpha", parent: String? = nil, status: String = "running",
        startedAt: String? = nil, endedAt: String? = nil
    ) -> LeoDispatch {
        LeoDispatch(id: id, name: "n-\(id)", status: status, callerAgent: caller, parentDispatchID: parent, startedAt: startedAt, endedAt: endedAt)
    }

    private func enabledTree(_ dispatches: [LeoDispatch] = []) -> LeoDispatchTree {
        var tree = LeoDispatchTree()
        tree.setEnabled(true)
        tree.applyBaseline(dispatches)
        return tree
    }

    private func ids(_ nodes: [LeoDispatchNode]) -> [String] { nodes.map(\.id) }

    @Test func rootsNestUnderTheirCallerAgentsRow() {
        let tree = enabledTree([dispatch("d1"), dispatch("d3", caller: "beta")])
        #expect(ids(tree.children(of: "alpha")) == ["d1"])
        #expect(tree.children(of: "alpha").map(\.depth) == [0])
        #expect(ids(tree.children(of: "beta")) == ["d3"])
        #expect(tree.children(of: "gamma").isEmpty)
    }

    /// Nesting keys on `parent_dispatch_id` first: a nested dispatch's
    /// `caller_agent` may not name an agent row at all.
    @Test func aGrandchildNestsByParentDispatchIDDepthFirst() {
        let tree = enabledTree([
            dispatch("d2", caller: "dispatch.d1", parent: "d1", startedAt: "2026-10-06T12:00:02Z"),
            dispatch("d1", startedAt: "2026-10-06T12:00:01Z"),
            dispatch("d4", startedAt: "2026-10-06T12:00:04Z"),
            dispatch("d3", caller: "dispatch.d2", parent: "d2", startedAt: "2026-10-06T12:00:03Z")
        ])
        let nodes = tree.children(of: "alpha")
        #expect(ids(nodes) == ["d1", "d2", "d3", "d4"])
        #expect(nodes.map(\.depth) == [0, 1, 2, 0])
    }

    @Test func aTerminalStatusOrEndedAtRemovesTheRecord() {
        var tree = enabledTree([dispatch("d1"), dispatch("d2")])
        let changed1 = tree.upsert(dispatch("d1", status: "done"))
        #expect(changed1)
        #expect(ids(tree.children(of: "alpha")) == ["d2"])
        let changed2 = tree.upsert(dispatch("d2", status: "running", endedAt: "2026-10-06T12:00:00Z"))
        #expect(changed2)
        #expect(tree.children(of: "alpha").isEmpty)
        let changed3 = tree.upsert(dispatch("d9", status: "failed"))
        #expect(!changed3, "an unknown id that is already over changes nothing")
    }

    @Test func idleAndSettlingStay() {
        var tree = enabledTree([dispatch("d1")])
        tree.upsert(dispatch("d1", status: "idle"))
        tree.upsert(dispatch("d2", status: "settling"))
        #expect(ids(tree.children(of: "alpha")) == ["d1", "d2"])
        #expect(tree.children(of: "alpha").first?.dispatch.status == "idle")
    }

    @Test func anUnchangedRecordReportsNoChange() {
        var tree = enabledTree()
        let changed4 = tree.upsert(dispatch("d1"))
        #expect(changed4)
        let changed5 = tree.upsert(dispatch("d1"))
        #expect(!changed5)
        let changed6 = tree.upsert(dispatch("d1", status: "idle"))
        #expect(changed6)
    }

    /// A `/state` taken before a live `done` must not bring the child back.
    @Test func aBaselineCannotResurrectAnIDThatEndedLive() {
        var tree = enabledTree()
        tree.upsert(dispatch("d1"))
        tree.upsert(dispatch("d1", status: "done"))
        tree.applyBaseline([dispatch("d1"), dispatch("d2")])
        #expect(ids(tree.children(of: "alpha")) == ["d2"])
        let changed7 = tree.upsert(dispatch("d1"))
        #expect(!changed7, "nor can a late live record")
    }

    @Test func aBaselineReplacesWhatWasThere() {
        var tree = enabledTree([dispatch("d1")])
        tree.applyBaseline([dispatch("d2"), dispatch("d3", status: "done")])
        #expect(ids(tree.children(of: "alpha")) == ["d2"])
    }

    /// A baseline fetched before a live update must not undo it: records
    /// upserted after `mark` (read when the fetch started) win.
    @Test func aBaselineKeepsWhatChangedLiveSinceItsFetchStarted() {
        var tree = enabledTree([dispatch("d1")])
        let mark = tree.mark
        tree.upsert(dispatch("d2"))
        tree.upsert(dispatch("d1", status: "idle"))
        tree.applyBaseline([dispatch("d1"), dispatch("d3")], since: mark)
        #expect(ids(tree.children(of: "alpha")) == ["d1", "d2", "d3"])
        #expect(tree.children(of: "alpha").first?.dispatch.status == "idle")
        tree.applyBaseline([dispatch("d3")], since: tree.mark)
        #expect(ids(tree.children(of: "alpha")) == ["d3"], "nothing changed since this one started")
    }

    /// The daemon republishes a live record every second. One that lands
    /// while `/state` is in flight proves the record is live as of after the
    /// fetch started, so a baseline that omits it must not drop it (it would
    /// come back on the next republish: a flicker).
    @Test func aBaselineRacingARepublishOfAnUnchangedRecordKeepsIt() {
        var tree = enabledTree([dispatch("d1")])
        let mark = tree.mark
        let changed = tree.upsert(dispatch("d1"))
        #expect(!changed, "an identical republish is not a visible change")
        tree.applyBaseline([], since: mark)
        #expect(ids(tree.children(of: "alpha")) == ["d1"])
        tree.applyBaseline([], since: tree.mark)
        #expect(tree.children(of: "alpha").isEmpty, "a fetch that began after the last confirmation does drop it")
    }

    /// A drop (no baseline at all) must not blank the tree: the next
    /// baseline, fetched after the reconnect, reconciles the stale rows.
    @Test func aReconnectBaselineReconcilesTheLastKnownRows() {
        var tree = enabledTree([dispatch("d1"), dispatch("d2")])
        let mark = tree.mark
        #expect(ids(tree.children(of: "alpha")) == ["d1", "d2"], "last-known rows survive the drop")
        tree.applyBaseline([dispatch("d2"), dispatch("d3")], since: mark)
        #expect(ids(tree.children(of: "alpha")) == ["d2", "d3"])
    }

    @Test func anEndedIDStaysGoneThroughAReconnectBaselineAndLateRepublish() {
        var tree = enabledTree([dispatch("d1")])
        tree.upsert(dispatch("d1", status: "done"))
        let mark = tree.mark
        tree.applyBaseline([dispatch("d1")], since: mark)
        let changed = tree.upsert(dispatch("d1"))
        #expect(!changed)
        #expect(tree.children(of: "alpha").isEmpty)
    }

    // MARK: state_seq

    private func seqTree(_ enabled: Bool = true) -> LeoDispatchTree {
        var tree = LeoDispatchTree()
        tree.setEnabled(true)
        tree.setStateSeq(enabled)
        return tree
    }

    /// The snapshot reflects only events up to its seq: a record whose last
    /// event is newer is not stale just because the snapshot omits it.
    @Test func aBaselineOlderThanARecordsLastEventKeepsIt() {
        var tree = seqTree()
        tree.upsert(dispatch("d1"), seq: 10)
        tree.applyBaseline([], since: tree.mark, atSeq: 5)
        #expect(ids(tree.children(of: "alpha")) == ["d1"])
        tree.applyBaseline([], since: tree.mark, atSeq: 10)
        #expect(tree.children(of: "alpha").isEmpty, "a snapshot that covers its last event is authoritative")
    }

    @Test func anEventTheBaselineAlreadyReflectsIsIgnored() {
        var tree = seqTree()
        tree.applyBaseline([dispatch("d1")], atSeq: 20)
        let stale = tree.upsert(dispatch("d1", status: "idle"), seq: 15)
        #expect(!stale)
        #expect(tree.children(of: "alpha").first?.dispatch.status == "running")
        let fresh = tree.upsert(dispatch("d1", status: "idle"), seq: 21)
        #expect(fresh)
        #expect(tree.children(of: "alpha").first?.dispatch.status == "idle")
    }

    @Test func anOlderEventCannotCreateARecordTheBaselineLacks() {
        var tree = seqTree()
        tree.applyBaseline([], atSeq: 20)
        let created = tree.upsert(dispatch("d9"), seq: 15)
        #expect(!created)
        #expect(tree.children(of: "alpha").isEmpty)
    }

    @Test func aNewerRecordSurvivesAnOlderBaselineThatHasItDifferently() {
        var tree = seqTree()
        tree.upsert(dispatch("d1", status: "idle"), seq: 30)
        tree.applyBaseline([dispatch("d1")], atSeq: 25)
        #expect(tree.children(of: "alpha").first?.dispatch.status == "idle")
    }

    @Test func withoutTheFeatureSeqsAreIgnoredAndMarksDecide() {
        var tree = seqTree(false)
        tree.upsert(dispatch("d1"), seq: 10)
        tree.applyBaseline([], since: tree.mark, atSeq: 5)
        #expect(tree.children(of: "alpha").isEmpty)
    }

    // MARK: dispatch_removed

    @Test func removingAnIDDropsItsRowAndAStaleBaselineCannotBringItBack() {
        var tree = enabledTree([dispatch("d1"), dispatch("d2")])
        let changed = tree.remove("d1")
        #expect(changed)
        #expect(ids(tree.children(of: "alpha")) == ["d2"])
        tree.applyBaseline([dispatch("d1"), dispatch("d2")])
        #expect(ids(tree.children(of: "alpha")) == ["d2"])
        let again = tree.remove("d1")
        #expect(!again)
        let unknown = tree.remove("nope")
        #expect(!unknown)
    }

    @Test func aTerminalRecordOmittedFromABaselineIsExpected() {
        var tree = enabledTree([dispatch("d1")])
        tree.upsert(dispatch("d1", status: "done"))
        tree.applyBaseline([])
        #expect(tree.children(of: "alpha").isEmpty)
    }

    @Test func anOrphanShowsUnderItsCallersRowOrNowhere() {
        let tree = enabledTree([
            dispatch("d2", caller: "dispatch.d9", parent: "d9"),
            dispatch("d5", caller: "alpha", parent: "d8")
        ])
        #expect(ids(tree.children(of: "alpha")) == ["d5"], "its parent is gone; its caller has a row")
        #expect(tree.projection(for: ["alpha", "beta"]) == ["alpha": tree.children(of: "alpha")], "d2 has no row to sit under")
    }

    @Test func resetClearsEverythingIncludingEndedIDs() {
        var tree = enabledTree([dispatch("d1")])
        tree.upsert(dispatch("d2"))
        tree.upsert(dispatch("d2", status: "done"))
        tree.reset()
        #expect(tree.children(of: "alpha").isEmpty)
        tree.setEnabled(true)
        tree.applyBaseline([dispatch("d2")])
        #expect(ids(tree.children(of: "alpha")) == ["d2"])
    }

    @Test func aNewBootForgetsEndedIDsButASameBootKeepsThem() {
        var tree = enabledTree()
        let changed8 = tree.observeBoot("boot-a")
        #expect(!changed8, "the first boot is not a change")
        tree.upsert(dispatch("d1"))
        tree.upsert(dispatch("d1", status: "done"))
        let changed9 = tree.observeBoot("boot-a")
        #expect(!changed9)
        tree.applyBaseline([dispatch("d1")])
        #expect(tree.children(of: "alpha").isEmpty)
        let changed10 = tree.observeBoot("boot-b")
        #expect(changed10)
        tree.applyBaseline([dispatch("d1")])
        #expect(ids(tree.children(of: "alpha")) == ["d1"])
    }

    @Test func endedIDsAreCapped() {
        var tree = enabledTree()
        for index in 0...LeoDispatchTree.endedCap {
            tree.upsert(dispatch("d\(index)", status: "done"))
        }
        tree.applyBaseline([dispatch("d0"), dispatch("d\(LeoDispatchTree.endedCap)")])
        #expect(ids(tree.children(of: "alpha")) == ["d0"], "the oldest ended id fell out of the cap")
    }

    @Test func nestingDeeperThanTheLimitIsNotShown() {
        let chain = (0...LeoDispatchTree.maxDepth + 2).map { index in
            dispatch("c\(index)", parent: index == 0 ? nil : "c\(index - 1)", startedAt: "2026-10-06T12:00:\(String(format: "%02d", index))Z")
        }
        let nodes = enabledTree(chain).children(of: "alpha")
        #expect(nodes.count == LeoDispatchTree.maxDepth + 1)
        #expect(nodes.last?.depth == LeoDispatchTree.maxDepth)
    }

    @Test func liveRecordsAreCapped() {
        var tree = enabledTree((0..<LeoDispatchTree.recordCap + 5).map { dispatch("r\($0)") })
        #expect(tree.children(of: "alpha").count == LeoDispatchTree.recordCap)
        let added = tree.upsert(dispatch("one-more"))
        #expect(!added, "a new id past the cap is ignored")
    }

    @Test func withTheFeatureOffNothingShows() {
        var tree = LeoDispatchTree()
        tree.applyBaseline([dispatch("d1")])
        tree.upsert(dispatch("d2"))
        #expect(tree.children(of: "alpha").isEmpty)
        #expect(tree.projection(for: ["alpha"]).isEmpty)
        tree.setEnabled(true)
        #expect(ids(tree.children(of: "alpha")) == ["d1", "d2"])
    }
}
