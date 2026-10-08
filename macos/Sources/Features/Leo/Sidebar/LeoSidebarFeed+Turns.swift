import Foundation

/// B-259 in the feed: the last-turn preview and usage on agent rows.
/// hello records which optional features the daemon has (shared plumbing
/// for the other bridge-derived row details); `bridge_turns` gates the
/// preview and `agent_usage` gates usage, so an older daemon renders
/// nothing new. Neither event merges a value except the preview text
/// (D-082): usage and turn events only ask for a fresh `/state` snapshot,
/// whose `usage` is what rows show.
extension LeoSidebarFeed {
    func receiveFeatures(bootID: String?, features: [String]) {
        // Only the current connection's events reach here (`receive(_:generation:)`
        // drops the rest), so `connectionHost` is the host that sent this hello.
        let advertised = LeoHostFeatures(host: connectionHost, features: LeoDaemonFeatures(features))
        let featuresChanged = advertised != hostFeatures
        hostFeatures = advertised
        // The /state baseline can land before the first hello; the features
        // alone decide what the rows already hold may show, so repaint.
        let before = turnPreviews
        turnPreviews = before.observingBoot(bootID)
        if featuresChanged || turnPreviews != before { emit() }
    }

    /// Records the preview for the row's current incarnation. Accepted loss:
    /// a turn arriving between `agent_spawned` and the `/state` refresh is
    /// stamped with the old `started_at`, stops matching once the new one
    /// lands, and drops -- it fails safe, never painting a namesake. A turn for an
    /// agent with no row (or none identified by `started_at`) is dropped:
    /// never paint a namesake, never invent a row.
    func receiveTurn(_ turn: LeoTurnCompletion) {
        guard daemonFeatures.contains(.bridgeTurns) else { return }
        if let startedAt = snapshot.rows.first(where: { $0.name == turn.agent })?.startedAt, !startedAt.isEmpty {
            updatingTurns { $0.recording(turn, startedAt: startedAt) }
        }
        requestMetadataRefresh()
    }

    func receiveUsageEvent() {
        guard daemonFeatures.contains(.agentUsage) else { return }
        requestMetadataRefresh()
    }

    func forgetTurn(_ name: String) {
        updatingTurns { $0.forgetting(name) }
    }

    /// Connection or host change: nothing carries over. Features go too;
    /// the next hello restates them.
    func resetTurns() {
        turnPreviews = .empty
        hostFeatures = .none
    }

    private func updatingTurns(_ change: (LeoTurnPreviews) -> LeoTurnPreviews) {
        let before = turnPreviews
        turnPreviews = change(before)
        guard turnPreviews != before else { return }
        emit()
    }
}

extension LeoSidebarSnapshot {
    /// Rows with their last turn and usage, each only when the daemon
    /// advertised it. None while disconnected: the rows are stale.
    func overlayingTurns(_ previews: LeoTurnPreviews, features: LeoDaemonFeatures) -> LeoSidebarSnapshot {
        let live = !connectivity.isDisconnected
        let showsTurns = live && features.contains(.bridgeTurns)
        let showsUsage = live && features.contains(.agentUsage)
        let withTurns = showsTurns ? previews.attach(to: rows) : rows.map { $0.withLastTurn(nil) }
        let shown = showsUsage ? withTurns : withTurns.map { row in
            guard row.metadata?.usage != nil else { return row }
            return row.withMetadata(row.metadata?.withUsage(nil))
        }
        return LeoSidebarSnapshot(
            rows: shown, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount, dispatchChildren: dispatchChildren
        )
    }
}
