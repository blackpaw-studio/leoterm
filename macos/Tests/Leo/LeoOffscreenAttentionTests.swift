import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-413: which rows that need the user are scrolled off the sidebar.
struct LeoOffscreenAttentionTests {
    typealias Candidate = LeoOffscreenAttention.Candidate

    private func candidate(_ name: String, at tableRow: Int, kind: LeoOffscreenAttention.Kind = .needsYou, unread: Int = 0) -> Candidate {
        Candidate(id: LeoAgentID(host: .local, name: name), name: name, tableRow: tableRow, kind: kind, unreadCount: unread)
    }

    // MARK: Rule

    private func row(
        attention: LeoAttentionBadge? = nil, status: LeoAgentStatus = .running, activity: LeoActivity = .idle
    ) -> LeoAgentRow {
        LeoAgentRow(
            host: .local, name: "a", template: nil, status: status, activity: activity, actionDetail: nil, attention: attention
        )
    }

    @Test func needsInputErroredAndFailedActionRowsCount() {
        #expect(LeoOffscreenAttention.kind(of: row(attention: .needsInput), error: nil, unread: 0) == .needsYou)
        #expect(LeoOffscreenAttention.kind(of: row(attention: .errored), error: nil, unread: 0) == .error)
        #expect(LeoOffscreenAttention.kind(of: row(), error: "restart failed", unread: 0) == .error)
    }

    @Test(arguments: [
        LeoAttentionBadge.working, .finished,
    ])
    func anyStateWithUnreadCounts(_ badge: LeoAttentionBadge) {
        #expect(LeoOffscreenAttention.kind(of: row(attention: badge), error: nil, unread: 2) == .unread)
    }

    @Test func workingFinishedIdleStoppedStartingAndStaleRowsNeverCount() {
        let rows = [
            row(attention: .working), row(attention: .finished), row(),
            row(status: .stopped), row(status: .starting), row(status: .restoring), row(status: .unknown("x")),
            row(activity: .working),
        ]
        for row in rows {
            #expect(LeoOffscreenAttention.kind(of: row, error: nil, unread: 0) == nil, "\(row.status) \(String(describing: row.attention))")
        }
    }

    @Test func aNeedsYouRowWithUnreadStillReadsNeedsYou() {
        #expect(LeoOffscreenAttention.kind(of: row(attention: .needsInput), error: nil, unread: 5) == .needsYou)
    }

    // MARK: Targets

    @Test func aRowAboveTheVisibleRowsShowsOnlyTheTopTarget() {
        let targets = LeoOffscreenAttention.targets(of: [candidate("a", at: 2)], visibleRows: 5 ... 12)
        #expect(targets.above?.name == "a")
        #expect(targets.below == nil)
    }

    @Test func aRowBelowShowsOnlyTheBottomTarget() {
        let targets = LeoOffscreenAttention.targets(of: [candidate("z", at: 30)], visibleRows: 5 ... 12)
        #expect(targets.above == nil)
        #expect(targets.below?.name == "z")
    }

    @Test func rowsAboveAndBelowShowBothIndependently() {
        let candidates = [candidate("a", at: 1), candidate("z", at: 30)]
        #expect(LeoOffscreenAttention.targets(of: candidates, visibleRows: 5 ... 12) == .init(above: candidates[0], below: candidates[1]))
        // Scrolling the top one into view leaves the bottom one.
        let scrolled = LeoOffscreenAttention.targets(of: candidates, visibleRows: 0 ... 12)
        #expect(scrolled.above == nil)
        #expect(scrolled.below?.name == "z")
    }

    @Test func theNearestRowInEachDirectionIsTheTarget() {
        let candidates = [
            candidate("far-up", at: 1), candidate("near-up", at: 4), candidate("near-down", at: 14), candidate("far-down", at: 40),
        ]
        let targets = LeoOffscreenAttention.targets(of: candidates, visibleRows: 5 ... 12)
        #expect(targets.above?.name == "near-up")
        #expect(targets.below?.name == "near-down")
    }

    @Test func aRowInViewShowsNoTarget() {
        let candidates = [candidate("in", at: 5), candidate("edge", at: 12), candidate("mid", at: 8)]
        #expect(LeoOffscreenAttention.targets(of: candidates, visibleRows: 5 ... 12) == .none)
    }

    @Test func anUnmeasuredListShowsNothing() {
        #expect(LeoOffscreenAttention.targets(of: [candidate("a", at: 1)], visibleRows: nil) == .none)
    }

    @Test func countsAreKeptPerEdge() {
        let candidates = [candidate("a", at: 0), candidate("b", at: 2), candidate("c", at: 20), candidate("d", at: 8)]
        let counts = LeoOffscreenAttention.offscreenCounts(of: candidates, visibleRows: 5 ... 12)
        #expect(counts.above == 2)
        #expect(counts.below == 1)
    }

    // MARK: Presentation

    @Test func oneRowReadsNeedsYouAndSeveralReadACount() {
        let target = candidate("alpha", at: 1)
        #expect(LeoOffscreenAttention.presentation(edge: .top, target: target, offscreenCount: 1).text == "Needs you")
        #expect(LeoOffscreenAttention.presentation(edge: .top, target: target, offscreenCount: 3).text == "3 need you")
    }

    @Test func theSpokenLabelNamesTheDirectionTheAgentAndTheReason() {
        let needs = LeoOffscreenAttention.presentation(edge: .top, target: candidate("alpha", at: 1), offscreenCount: 1)
        #expect(needs.accessibilityLabel == "Scroll up to alpha, needs you")
        let error = LeoOffscreenAttention.presentation(edge: .bottom, target: candidate("beta", at: 1, kind: .error), offscreenCount: 1)
        #expect(error.accessibilityLabel == "Scroll down to beta, error")
        let unread = LeoOffscreenAttention.presentation(edge: .bottom, target: candidate("g", at: 1, kind: .unread, unread: 3), offscreenCount: 1)
        #expect(unread.accessibilityLabel == "Scroll down to g, 3 unread messages")
    }
}
