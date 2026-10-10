import Foundation

/// B-283 in the feed: the rows' effective environment names. Every applied
/// `/state` replaces them (see `applyMetadata`), and an event carrying the
/// fields patches them; a lifecycle event that omits them changes nothing.
/// Rows show them only while the host advertises `agent_environments`.
extension LeoSidebarFeed {
    func receiveEnvironments(_ event: LeoObserveEvent) {
        let patched: (String, LeoAgentEnvironmentsPatch)? = switch event {
        case .agentSpawned(_, _, let agent, _, let patch?): (agent.name, patch)
        case .agentStateChanged(_, _, let agent, _, _, _, let patch?): (agent, patch)
        default: nil
        }
        guard let (name, patch) = patched else { return }
        let before = environments
        environments = before.patching(name, with: patch)
        if environments != before { emit() }
    }
}

extension LeoSidebarSnapshot {
    /// Rows with their environments, only when the daemon advertised them.
    /// None while disconnected: the rows are stale.
    func overlayingEnvironments(_ index: LeoAgentEnvironmentsIndex, features: LeoDaemonFeatures) -> LeoSidebarSnapshot {
        let shows = !connectivity.isDisconnected && features.contains(.agentEnvironments)
        let shown = rows.map { $0.withEnvironments(shows ? index[$0.name] : nil) }
        return LeoSidebarSnapshot(
            rows: shown, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount, dispatchChildren: dispatchChildren
        )
    }
}
