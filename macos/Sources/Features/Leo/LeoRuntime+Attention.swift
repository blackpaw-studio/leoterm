import Foundation

/// Attention-model hooks on the runtime: focus identity into the feed's
/// reducer, and Agents ▸ Jump to Next Needing Attention.
extension LeoRuntime {
    /// Focus identity comes only from `LeoAttachCoordinator`'s
    /// handle -> identity map, never from titles or sidebar selection.
    func focusedAgentChanged(_ identity: LeoAgentIdentity?) {
        let id = identity.map { LeoAgentRow.ID(host: $0.host, name: $0.name) }
        Task { [feed] in await feed.setFocusedAgent(id) }
    }

    /// The row Jump would attach to: unfiltered sidebar order, after the
    /// focused agent (else the selection), skipping the focused agent.
    var nextAttentionTarget: LeoAgentRow? {
        let rows = LeoSidebarReducers.rank(model.snapshot.rows)
        let focused = attachCoordinator.focusedIdentity.map { LeoAgentRow.ID(host: $0.host, name: $0.name) }
        let target = LeoAttentionNavigation.next(
            in: rows.map(\.id),
            needing: LeoAttentionNavigation.needing(rows),
            focused: focused,
            selected: model.selection
        )
        return rows.first { $0.id == target }
    }

    /// Reveals `session`'s sidebar, clears a filter that would hide the
    /// target, and attaches (reusing a tab when one exists). The selection
    /// moves only once the attach succeeds.
    func jumpToNextNeedingAttention(from session: LeoWindowSession) {
        guard let row = nextAttentionTarget else { return }
        session.setSidebarVisible(true)
        if LeoAttentionNavigation.filterHides(row, query: model.query) { model.query = "" }
        let request = LeoSurfaceRequest(origin: session.id, disposition: .tab)
        Task { [weak self] in
            guard let self else { return }
            if case .success = await self.attachCoordinator.attach(identity: row.identity, request: request) {
                self.model.selection = row.id
            }
        }
    }
}
