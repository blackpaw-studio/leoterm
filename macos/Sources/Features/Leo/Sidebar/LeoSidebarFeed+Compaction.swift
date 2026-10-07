import Foundation

/// B-261 in the feed: which agents are compacting. `/state` has no such
/// field, so the `agent_compaction` events are the only source (the same
/// exception the turn preview is, D-393). The end event clears the entry
/// and asks for a fresh `/state`, whose `usage.context.percent` is what
/// rows then show: the event's own percentage predates the compaction and
/// is never displayed. Never a timer (principle 5): a lost end event is
/// cleared by the next gap, reconnect, boot change, stop, spawn or turn end.
extension LeoSidebarFeed {
    /// `started` marks the row's current incarnation; an event for an agent
    /// with no row (or none identified by `started_at`) is dropped -- never
    /// paint a namesake, never invent a row.
    func receiveCompaction(_ event: LeoCompactionEvent) {
        switch event.phase {
        case .started:
            guard let startedAt = snapshot.rows.first(where: { $0.name == event.agent })?.startedAt, !startedAt.isEmpty else { return }
            updatingCompactions { $0.recording(event, startedAt: startedAt) }
        case .completed, .failed:
            endCompaction(event.agent)
            requestMetadataRefresh()
        }
    }

    func endCompaction(_ name: String) {
        updatingCompactions { $0.ending(name) }
    }

    func observeCompactionBoot(_ bootID: String?) {
        updatingCompactions { $0.observingBoot(bootID) }
    }

    /// Connection, host or stream change: nothing carries over.
    func resetCompactions() {
        compactions = .empty
    }

    private func updatingCompactions(_ change: (LeoCompactions) -> LeoCompactions) {
        let before = compactions
        compactions = change(before)
        guard compactions != before else { return }
        emit()
    }
}

extension LeoSidebarSnapshot {
    /// Rows with their compaction in progress; none while disconnected,
    /// when the rows are stale.
    func overlayingCompactions(_ compactions: LeoCompactions) -> LeoSidebarSnapshot {
        let shown = connectivity.isDisconnected ? rows.map { $0.withCompaction(nil) } : compactions.attach(to: rows)
        return LeoSidebarSnapshot(
            rows: shown, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount, dispatchChildren: dispatchChildren
        )
    }
}
