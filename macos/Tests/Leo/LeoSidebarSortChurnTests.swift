import Foundation
import Testing

@testable import Ghostty

/// B-063: "The order of the running agents in the sidebar keeps switching
/// around." Every activity burst brings a fresh `/state` snapshot, and
/// `last_activity_at` has one-second resolution, so busy agents used to
/// leapfrog each other on every snapshot. Last Activity now ranks active
/// rows by when their streak of activity began, carried from snapshot to
/// snapshot, so busy agents hold their places and only a row that becomes
/// active (or goes quiet) moves.
struct LeoSidebarSortChurnTests {
    private static let base = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func busyAgentsDoNotLeapfrogAcrossSnapshots() {
        // Each snapshot moves every time by 1-20s; the newest rotates a -> b -> c -> a.
        let snapshots: [[String: TimeInterval]] = [
            ["a": 100, "b": 95, "c": 90],
            ["a": 101, "b": 105, "c": 91],
            ["a": 102, "b": 106, "c": 111],
            ["a": 113, "b": 107, "c": 112],
            ["a": 114, "b": 120, "c": 113],
            ["a": 115, "b": 121, "c": 125]
        ]
        let orders = Self.orders(snapshots.map { Self.state($0) })
        #expect(orders.first == ["a", "b", "c"])
        #expect(orders.allSatisfy { $0 == orders.first }, "\(orders)")
    }

    @Test func aStaleAgentThatBecomesActiveRises() {
        let orders = Self.orders([
            Self.state(["a": 10000, "b": 9990, "s": 10000 - 7200]),
            Self.state(["a": 10005, "b": 10010, "s": 10010])
        ])
        #expect(orders == [["a", "b", "s"], ["s", "a", "b"]])
    }

    @Test func anAgentThatGoesQuietDropsBelowStillActiveOnes() {
        // b stops at 1010; a keeps working. The window is five minutes.
        let orders = Self.orders([1000, 1100, 1300, 1400, 1500].map { Self.state(["a": $0, "b": 1010]) })
        #expect(orders == [["b", "a"], ["b", "a"], ["b", "a"], ["a", "b"], ["a", "b"]])
        let moves = zip(orders, orders.dropFirst()).filter { $0 != $1 }.count
        #expect(moves == 1)
    }

    @Test func aRecreatedIncarnationStartsAFreshStreak() throws {
        let first = LeoAgentMetadataIndex(state: Self.state(["x": 1000, "y": 1005]), previous: .empty)
        let same = LeoAgentMetadataIndex(state: Self.state(["x": 1010, "y": 1020]), previous: first)
        #expect(same.metadata(name: "x", startedAt: "s")?.activeSince == Self.time(1000), "the same incarnation keeps its streak")

        let recreated = LeoAgentMetadataIndex(
            state: [Self.observed("x", startedAt: "s-new", at: 1010), Self.observed("y", startedAt: "s", at: 1020)],
            previous: first
        )
        let fresh = try #require(recreated.metadata(name: "x", startedAt: "s-new"))
        #expect(fresh.activeSince == Self.time(1010))
        let rows = recreated.attach(to: [Self.row("x", startedAt: "s-new"), Self.row("y", startedAt: "s")])
        #expect(LeoSidebarLayout.sorted(rows, by: .lastActivity).map(\.name) == ["x", "y"])
    }

    @Test func aSingleSnapshotStillSortsNewestFirst() {
        let orders = Self.orders([Self.state(["old": 10, "mid": 5000, "new": 5100, "gone": 1])])
        #expect(orders == [["new", "mid", "old", "gone"]])
    }

    @Test func aRowThatReportsNoTimeKeepsNoStreak() {
        let first = LeoAgentMetadataIndex(state: Self.state(["a": 100]), previous: .empty)
        let next = LeoAgentMetadataIndex(
            state: [LeoObservedAgent(
                name: "a", status: .running, activity: .idle, currentAction: .init(kind: "pane", detail: "Reading"),
                lastActivityAt: nil, startedAt: "s"
            )],
            previous: first
        )
        #expect(next.metadata(name: "a", startedAt: "s")?.activeSince == nil)
    }

    // MARK: Helpers

    /// The Last Activity order after each snapshot, each index carrying
    /// the one before it.
    private static func orders(_ snapshots: [[LeoObservedAgent]]) -> [[String]] {
        var index = LeoAgentMetadataIndex.empty
        return snapshots.map { state in
            index = LeoAgentMetadataIndex(state: state, previous: index)
            let rows = index.attach(to: state.map { row($0.name, startedAt: $0.startedAt ?? "") })
            return LeoSidebarLayout.sorted(rows, by: .lastActivity).map(\.name)
        }
    }

    private static func state(_ times: [String: TimeInterval]) -> [LeoObservedAgent] {
        times.keys.sorted().map { observed($0, startedAt: "s", at: times[$0] ?? 0) }
    }

    private static func time(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    private static func observed(_ name: String, startedAt: String, at seconds: TimeInterval) -> LeoObservedAgent {
        let formatter = ISO8601DateFormatter()
        return LeoObservedAgent(
            name: name, status: .running, activity: .working, currentAction: nil,
            lastActivityAt: formatter.string(from: time(seconds)), startedAt: startedAt
        )
    }

    private static func row(_ name: String, startedAt: String) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: nil, status: .running, activity: .idle, actionDetail: nil, startedAt: startedAt)
    }
}
