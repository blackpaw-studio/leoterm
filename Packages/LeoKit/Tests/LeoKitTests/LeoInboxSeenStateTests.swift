import Foundation
import Testing

@testable import LeoKit

struct LeoInboxSeenStateTests {
    typealias Fx = LeoInboxFixtures

    private func finished(_ name: String, revision: Int = 1, at: TimeInterval? = 10, bootID: String? = "boot") -> LeoInboxItem {
        let agent = Fx.agent(name, signal: Fx.signal(.finished, revision, at: at), bootID: bootID)
        return LeoInbox.derive(agents: [agent], openAsks: [:], seen: LeoInboxSeenState()).finished[0]
    }

    private func unread(_ seen: LeoInboxSeenState, _ item: LeoInboxItem) -> Bool {
        seen.isUnread(item.id, at: item.at, revision: item.revision, bootID: item.bootID)
    }

    @Test func syncedItemIsUnreadOnlyWhenNewerThanSeenAt() {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: ["zeus": Fx.at(10)])

        #expect(!unread(seen, finished("zeus", at: 10)))
        #expect(!unread(seen, finished("zeus", at: 5)))
        #expect(unread(seen, finished("zeus", at: 11)))
        #expect(unread(seen, finished("hera", at: 1)), "no mark for that agent")
    }

    @Test func localItemIsUnreadUntilMarkedAndAgainOnANewRevision() {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: nil)
        let item = finished("zeus", revision: 4)

        #expect(unread(seen, item))
        seen.markSeen(item.id, at: item.at, revision: item.revision, bootID: item.bootID, now: Fx.at(100))
        #expect(!unread(seen, item))
        #expect(unread(seen, finished("zeus", revision: 5)), "a new revision is unread")
        #expect(unread(seen, finished("zeus", revision: 4, bootID: "other-boot")), "a daemon restart re-flags it once")
    }

    @Test func markingSeenInSyncedModeSilencesTheItemUntilALaterFinish() {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: [:])
        let item = finished("zeus", at: 10)

        seen.markSeen(item.id, at: item.at, revision: item.revision, bootID: item.bootID, now: Fx.at(20))

        #expect(!unread(seen, item))
        #expect(unread(seen, finished("zeus", at: 30)))
    }

    @Test func markSeenIsForwardOnlyEvenWhenTheClockIsBehindTheItem() {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: [:])
        let item = finished("zeus", at: 500)

        seen.markSeen(item.id, at: item.at, revision: item.revision, bootID: item.bootID, now: Fx.at(100))

        #expect(!unread(seen, item), "marking an item seen covers that item even if the local clock lags the daemon's")
    }

    @Test func anAgentSeenEventAdvancesAndNeverRewinds() {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: ["zeus": Fx.at(50)])

        seen.apply(host: Fx.host, agent: "zeus", seenAt: Fx.at(20))
        #expect(!unread(seen, finished("zeus", at: 40)))
        seen.apply(host: Fx.host, agent: "zeus", seenAt: Fx.at(60))
        #expect(!unread(seen, finished("zeus", at: 55)))
    }

    @Test func reseedingNeverRewindsAMark() {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: ["zeus": Fx.at(50)])
        seen.seed(host: Fx.host, seen: ["zeus": Fx.at(20)])

        #expect(!unread(seen, finished("zeus", at: 40)))
    }

    @Test func anAgentSeenEventBeforeSeedingStartsSyncedMarks() {
        var seen = LeoInboxSeenState()
        seen.apply(host: Fx.host, agent: "zeus", seenAt: Fx.at(60))
        #expect(!unread(seen, finished("zeus", at: 55)))
    }

    @Test func clearMarksEveryShownFinishedItemAndNeverABlockedOne() {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: [:])
        let agents = [
            Fx.agent("f1", signal: Fx.signal(.finished, at: 10)),
            Fx.agent("f2", signal: Fx.signal(.errored, at: 20)),
            Fx.agent("b1", signal: Fx.signal(.needsInput, at: 30)),
        ]
        let before = LeoInbox.derive(agents: agents, openAsks: [:], seen: seen)

        seen.clear(before.finished + before.blocked, now: Fx.at(100))
        let after = LeoInbox.derive(agents: agents, openAsks: [:], seen: seen)

        #expect(after.finished.map(\.isUnread) == [false, false])
        #expect(after.blocked.map(\.id.name) == ["b1"], "blocked items are never cleared")
        #expect(seen.isUnread(Fx.id("b1"), at: Fx.at(30), revision: 1, bootID: "boot"))
    }

    @Test func eachHostKeepsItsOwnMode() {
        var seen = LeoInboxSeenState()
        let other = LeoHostID.local
        seen.seed(host: Fx.host, seen: ["zeus": Fx.at(50)])
        seen.seed(host: other, seen: nil)

        #expect(!seen.isUnread(Fx.id("zeus"), at: Fx.at(40), revision: 1, bootID: "b"))
        #expect(seen.isUnread(Fx.id("zeus", host: other), at: Fx.at(40), revision: 1, bootID: "b"))
    }

    @Test func roundTripsThroughCodable() throws {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: ["zeus": Fx.at(50)])
        seen.seed(host: .local, seen: nil)
        seen.markSeen(Fx.id("a", host: .local), at: nil, revision: 3, bootID: "boot", now: Fx.at(1))

        let decoded = try JSONDecoder().decode(LeoInboxSeenState.self, from: JSONEncoder().encode(seen))

        #expect(decoded == seen)
    }
}
