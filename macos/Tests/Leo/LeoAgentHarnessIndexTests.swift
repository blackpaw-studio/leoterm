import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// `harness` reaches rows from the observe snapshot, like display names do.
struct LeoAgentHarnessIndexTests {
    private static func observed(_ name: String, harness: String?) -> LeoObservedAgent {
        LeoObservedAgent(name: name, status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil, harness: harness)
    }

    private static func snapshot(_ names: [String]) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: names.map { LeoAgentRow(host: .local, name: $0, template: nil, status: .running, activity: .idle, actionDetail: nil) },
            connectivity: .connected, generation: 1, listRefreshSucceeded: true
        )
    }

    @Test func harnessReachesTheRowByName() {
        let index = LeoAgentHarnessIndex(state: [Self.observed("alpha", harness: "codex"), Self.observed("beta", harness: nil)])
        let rows = Self.snapshot(["alpha", "beta", "gamma"]).overlayingHarness(index).rows
        #expect(rows.map(\.harness) == ["codex", nil, nil])
    }

    @Test func otherOverlaysKeepTheHarness() {
        let row = LeoAgentRow(host: .local, name: "a", template: nil, status: .running, activity: .idle, actionDetail: nil).withHarness("claude")
        #expect(row.withAppearance(nil).withTasks(.none).withDisplayName("A").withMetadata(nil).harness == "claude")
    }
}
