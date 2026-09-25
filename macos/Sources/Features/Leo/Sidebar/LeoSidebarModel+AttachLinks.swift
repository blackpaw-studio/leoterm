import AppKit

/// B-006: the sidebar selection follows the focused attach surface, and a
/// click on a row whose agent already has a live attach brings it forward.
extension LeoSidebarModel {
    /// Selects the focused agent's row when focus moves to it. A count-only
    /// change never reselects (it would yank arrow-key selection back).
    /// Focus leaving every attachment, or landing on an agent this sidebar
    /// isn't showing (another host), keeps the selection rather than
    /// inventing one. A report that was already in flight when the user
    /// last selected a row (e.g. the one a click's window activation
    /// yields) updates the link state but never the selection.
    func receiveAttachLinks(_ links: LeoAttachLinkState) {
        let previousFocus = attachLinks.focused
        attachLinks = links
        guard links.focused != previousFocus, !isFencedByUserSelection(links) else { return }
        selectFocusedRow()
    }

    /// Called after a snapshot lands: a focused row that just came into
    /// view (e.g. switching hosts away and back) is reselected. A refresh
    /// that already showed it leaves the selection alone.
    func reapplyFocusedRow(previousRows: [LeoAgentRow]) {
        guard let focused = attachLinks.focused, !previousRows.contains(where: { $0.id == focused }) else { return }
        selectFocusedRow()
    }

    /// The list's own selection change (click, arrow keys).
    func userSelected(_ id: LeoAgentRow.ID?) {
        selection = id
        fenceInFlightFocusReports()
    }

    func tabCount(for id: LeoAgentRow.ID) -> Int { attachLinks.tabCount(for: id) }

    /// A single click. The clicked row wins over any focus the click's
    /// window activation reported first. Rows without a live attach keep
    /// plain selection; Option defers to the double-click's new window.
    /// ⌘-click attaches a new tab in `origin`'s window even when the agent
    /// has one (B-047, Safari's convention) -- once: a ⌘-double-click's
    /// second click (`clickCount` 2) leaves it to the double-click, which
    /// brings that new tab forward.
    func rowClicked(
        _ row: LeoAgentRow,
        modifierFlags: NSEvent.ModifierFlags = [],
        clickCount: Int = 1,
        from origin: LeoWindowID? = nil
    ) {
        selection = row.id
        fenceInFlightFocusReports()
        if modifierFlags.contains(.command) {
            guard clickCount == 1, let origin else { return }
            requestAttach(row, from: origin, disposition: .newTab)
            return
        }
        guard !modifierFlags.contains(.option), tabCount(for: row.id) > 0 else { return }
        focusExistingRequested(row)
    }

    private func fenceInFlightFocusReports() {
        userSelectionFence = latestFocusReport()
    }

    private func isFencedByUserSelection(_ links: LeoAttachLinkState) -> Bool {
        guard let userSelectionFence else { return false }
        return links.focusReport <= userSelectionFence
    }

    private func selectFocusedRow() {
        guard let focused = attachLinks.focused, focused != selection,
              snapshot.rows.contains(where: { $0.id == focused }) else { return }
        selection = focused
    }
}
