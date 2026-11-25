import Foundation
import LeoKit

/// Agent briefs in the feed: every applied `/state` replaces them,
/// `agent_brief` sets one agent's whole brief, and `brief_config_changed`
/// clears them all (off) or refetches `/state` (on). Rows show them only
/// while the host advertises `agent_brief`.
extension LeoSidebarFeed {
    func receiveBrief(_ name: String, _ value: LeoAgentBrief?) {
        let before = briefs
        briefs = before.setting(name, to: value)
        if briefs != before { emit() }
        // A /state already in flight may predate this write; the trailing
        // refetch restates it so a late snapshot can't undo the event.
        requestMetadataRefresh()
    }

    func receiveBriefConfig(enabled: Bool) {
        if !enabled, briefs != .empty {
            briefs = .empty
            emit()
        }
        requestMetadataRefresh()
    }
}

extension LeoSidebarSnapshot {
    /// Rows with their briefs, only when the daemon advertised `agent_brief`.
    /// None while disconnected: the rows are stale.
    func overlayingBriefs(_ index: LeoAgentBriefIndex, features: LeoDaemonFeatures) -> LeoSidebarSnapshot {
        let shows = !connectivity.isDisconnected && features.contains(.agentBrief)
        return LeoSidebarSnapshot(
            rows: rows.map { $0.withBrief(shows ? index[$0.name] : nil) }, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount, dispatchChildren: dispatchChildren
        )
    }
}
