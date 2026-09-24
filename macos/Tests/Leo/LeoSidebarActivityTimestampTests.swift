import Foundation
import Testing

@testable import Ghostty

/// B-010: the daemon's `last_activity_at` (from `/observe/state`) and the
/// `at` stamp of `agent_activity` "working" events feed the sidebar's
/// Last Activity sort. Nothing else sets a time.
struct LeoSidebarActivityTimestampTests {
    @Test func parsesGoRFC3339NanoTimestamps() throws {
        let nano = try #require(LeoTimestamp.parse("2026-09-24T10:57:05.123456789-04:00"))
        let whole = try #require(LeoTimestamp.parse("2026-09-24T14:57:05Z"))
        #expect(abs(nano.timeIntervalSince(whole) - 0.123) < 0.001)
        #expect(LeoTimestamp.parse(nil) == nil)
        #expect(LeoTimestamp.parse("") == nil)
        #expect(LeoTimestamp.parse("yesterday") == nil)
    }

    @Test func stateBaselineCarriesLastActivityAt() {
        let agents = [
            LeoObservedAgent(name: "a", status: .running, activity: .idle, currentAction: nil, lastActivityAt: "2026-09-24T14:57:05Z"),
            LeoObservedAgent(name: "b", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil)
        ]
        let activities = LeoSidebarFeed.activities(agents)
        #expect(activities["a"]?.lastActivityAt == LeoTimestamp.parse("2026-09-24T14:57:05Z"))
        #expect(activities["b"]?.lastActivityAt == nil)
    }

    @Test func aWorkingEventAdvancesLastActivityToItsStamp() {
        let before = LeoSidebarActivity(activity: .idle, detail: nil, lastActivityAt: Date(timeIntervalSince1970: 100))
        let merged = LeoSidebarActivity.merging(before, activity: .working, detail: "x", at: Date(timeIntervalSince1970: 200))
        #expect(merged == LeoSidebarActivity(activity: .working, detail: "x", lastActivityAt: Date(timeIntervalSince1970: 200)))
    }

    @Test func anIdleEventKeepsTheLastActivityTime() {
        let before = LeoSidebarActivity(activity: .working, detail: nil, lastActivityAt: Date(timeIntervalSince1970: 100))
        let merged = LeoSidebarActivity.merging(before, activity: .idle, detail: nil, at: Date(timeIntervalSince1970: 200))
        #expect(merged.lastActivityAt == Date(timeIntervalSince1970: 100))
        #expect(merged.activity == .idle)
    }

    @Test func anOlderWorkingStampNeverMovesTimeBackwards() {
        let before = LeoSidebarActivity(activity: .idle, detail: nil, lastActivityAt: Date(timeIntervalSince1970: 300))
        let merged = LeoSidebarActivity.merging(before, activity: .working, detail: nil, at: Date(timeIntervalSince1970: 200))
        #expect(merged.lastActivityAt == Date(timeIntervalSince1970: 300))
    }

    @Test func aWorkingEventWithoutAStampInventsNoTime() {
        let merged = LeoSidebarActivity.merging(nil, activity: .working, detail: nil, at: nil)
        #expect(merged.lastActivityAt == nil)
    }

    @Test func mergeActivityCarriesTheTimeOntoRowsIncludingStoppedOnes() {
        let time = Date(timeIntervalSince1970: 42)
        let running = LeoAgentRow(host: .local, name: "r", template: nil, status: .running, activity: .unknown, actionDetail: nil)
        let stopped = LeoAgentRow(host: .local, name: "s", template: nil, status: .stopped, activity: .unknown, actionDetail: nil)
        let merged = LeoSidebarReducers.mergeActivity([running, stopped], activityByName: [
            "r": .init(activity: .working, detail: nil, lastActivityAt: time),
            "s": .init(activity: .working, detail: "x", lastActivityAt: time)
        ])
        #expect(merged.map(\.lastActivityAt) == [time, time])
        #expect(merged[1].activity == .unknown)
        #expect(merged[1].actionDetail == nil)
    }

    @Test func attentionOverlayKeepsLastActivityAt() {
        let time = Date(timeIntervalSince1970: 42)
        let row = LeoAgentRow(host: .local, name: "r", template: nil, status: .running, activity: .idle, actionDetail: nil, lastActivityAt: time)
        #expect(row.withAttention(nil).lastActivityAt == time)
    }
}
