import Foundation
import LeoKit

/// Daemon `display_name`s in the feed. `/agents/list` omits them, so rows
/// take them from `/state` (replaced whole by each applied snapshot, see
/// `applyMetadata`) and from `agent.spawned`, which restates the field for
/// the new incarnation: a recreated namesake without one drops the old name.
extension LeoSidebarFeed {
    func receiveDisplayName(_ event: LeoObserveEvent) {
        guard case .agentSpawned(_, _, let agent, _, _) = event else { return }
        let before = displayNames
        displayNames = before.spawning(agent.name, displayName: agent.daemonDisplayName)
        if displayNames != before { emit() }
    }
}

extension LeoSidebarSnapshot {
    /// Rows showing their daemon display name; a row the index has none for
    /// keeps whatever it already shows (its raw name).
    func overlayingDisplayNames(_ index: LeoAgentDisplayNameIndex) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: rows.map { row in index[row.name].map(row.withDisplayName) ?? row }, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount, dispatchChildren: dispatchChildren
        )
    }
}
