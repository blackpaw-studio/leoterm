import Foundation
import LeoKit

/// B-331: an agent row with dispatch children collapses just those rows
/// (its own chevron), and View ▸ Hide Subagents collapses or expands every
/// agent's at once. Kept in the sidebar preferences, so it survives a
/// relaunch. The parent row itself never changes: its state is still the
/// daemon's, and the running count is the only thing a collapsed row adds.
extension LeoSidebarModel {
    var hidesSubagents: Bool { preferences.hidesSubagents }

    func areSubagentsCollapsed(_ row: LeoAgentRow) -> Bool { preferences.isSubagentsCollapsed(row.id) }

    /// Whether `row` has any dispatch rows to disclose.
    func hasSubagents(_ row: LeoAgentRow) -> Bool { !dispatchChildren(for: row).isEmpty }

    /// The dispatches under `row`, at any depth, that are running now (a
    /// stalled one is shown as stalled, not running).
    func runningSubagentCount(for row: LeoAgentRow) -> Int {
        dispatchChildren(for: row).filter { $0.dispatch.status == "running" && !$0.dispatch.stalled }.count
    }

    func toggleSubagentsCollapsed(_ row: LeoAgentRow) {
        update(preferences.togglingSubagents(of: row.id))
        if areSubagentsCollapsed(row) { moveSelectionOutOfCollapsedAgent(row.id) }
    }

    func toggleHideSubagents() {
        update(preferences.settingHidesSubagents(!preferences.hidesSubagents))
        guard preferences.hidesSubagents, let parent = dispatchSelection?.parent else { return }
        moveSelectionOutOfCollapsedAgent(parent)
    }

    /// Collapsing hides a selected dispatch, so the agent it sits under
    /// takes the selection back (as when a nested dispatch collapses).
    private func moveSelectionOutOfCollapsedAgent(_ id: LeoAgentRow.ID) {
        guard dispatchSelection?.parent == id else { return }
        dispatchSelection = nil
    }
}
