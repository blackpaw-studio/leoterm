import Foundation
import Testing

@testable import LeoKit

struct LeoInboxBadgeTests {
    typealias F = LeoInboxFixtures

    private func inbox(blocked: Int = 0, unreadFinished: Int = 0, readFinished: Int = 0) -> LeoInbox {
        var seen = LeoInboxSeenState()
        seen.seed(host: F.host, seen: (0..<readFinished).reduce(into: [:]) { $0["read\($1)"] = F.at(1000) })
        let agents =
            (0..<blocked).map { F.agent("b\($0)", signal: F.signal(.needsInput, at: 1)) }
            + (0..<unreadFinished).map { F.agent("u\($0)", signal: F.signal(.finished, at: 2000)) }
            + (0..<readFinished).map { F.agent("read\($0)", signal: F.signal(.finished, at: 1)) }
        return LeoInbox.derive(agents: agents, openAsks: [:], seen: seen)
    }

    @Test func blockedItemsShowAsACount() {
        #expect(LeoInboxBadge(inbox(blocked: 3, unreadFinished: 2)) == .count(3))
    }

    @Test func unreadFinishedWithNothingBlockedIsADot() {
        #expect(LeoInboxBadge(inbox(unreadFinished: 1)) == .dot)
    }

    @Test func readFinishedAloneShowsNothing() {
        #expect(LeoInboxBadge(inbox(readFinished: 2)) == LeoInboxBadge.none)
        #expect(LeoInboxBadge(inbox()) == LeoInboxBadge.none)
    }

    @Test func summaryCountsBlockedAndUnreadFinished() {
        let summary = inbox(blocked: 3, unreadFinished: 2, readFinished: 4).summary

        #expect(summary == LeoInboxSummary(needYou: 3, unreadFinished: 2, finished: 6))
    }
}
