import Foundation
import LeoKit

/// Agent appearance in the feed: every applied `/state` replaces it (see
/// `applyMetadata`), and `agent_appearance_changed` sets one agent's whole
/// value at once. Rows show it only while the host advertises
/// `agent_appearance`.
extension LeoSidebarFeed {
    func receiveAppearance(_ name: String, _ value: LeoAgentAppearance?) {
        let before = appearance
        appearance = before.setting(name, to: value)
        if appearance != before { emit() }
        // A /state already in flight may predate this change; the trailing
        // refetch restates it so a late snapshot can't undo the event.
        requestMetadataRefresh()
    }
}

extension LeoSidebarSnapshot {
    /// Rows with their appearance, only when the daemon advertised it.
    /// None while disconnected: the rows are stale.
    func overlayingAppearance(_ index: LeoAgentAppearanceIndex, features: LeoDaemonFeatures) -> LeoSidebarSnapshot {
        let shows = !connectivity.isDisconnected && features.contains(.agentAppearance)
        return LeoSidebarSnapshot(
            rows: rows.map { $0.withAppearance(shows ? index[$0.name] : nil) }, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount, dispatchChildren: dispatchChildren
        )
    }
}
