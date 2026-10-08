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
        dispatchSelection = nil
        fenceInFlightFocusReports()
    }

    func attachCount(for id: LeoAgentRow.ID) -> Int { attachLinks.attachCount(for: id) }

    /// Every click on a row, the one place a click's meaning is decided.
    /// The clicked row wins over any focus the click's window activation
    /// reported first. A third click and beyond only select.
    func rowClicked(
        _ row: LeoAgentRow,
        modifierFlags: NSEvent.ModifierFlags = [],
        clickCount: Int = 1,
        from origin: LeoWindowID? = nil
    ) {
        selectAgentRow(row.id)
        fenceInFlightFocusReports()
        switch clickCount {
        case 1: singleClicked(row, modifierFlags: modifierFlags, from: origin)
        case 2: doubleClicked(row, modifierFlags: modifierFlags, from: origin)
        default: break
        }
    }

    /// A click goes to the agent (B-049): the window already showing it,
    /// else this window's content area; an agent that isn't running asks
    /// to start first (see `+StartPrompt`). ⌘-click opens it in a new
    /// window, or brings forward the one showing it (B-055, D-104).
    /// Option defers to the double-click's new window.
    private func singleClicked(_ row: LeoAgentRow, modifierFlags: NSEvent.ModifierFlags, from origin: LeoWindowID?) {
        if modifierFlags.contains(.command) {
            go(to: row, from: origin, disposition: .newWindow)
            return
        }
        guard !modifierFlags.contains(.option) else { return }
        if row.status == .running, attachCount(for: row.id) > 0 {
            focusExistingRequested(row, origin)
            return
        }
        go(to: row, from: origin, disposition: .content)
    }

    /// The first click already went to the agent, so a plain second click
    /// does nothing more (B-048). ⌥ opens it in a new window; a
    /// ⌘-double-click's second click brings the first click's window
    /// forward (D-093). Neither asks twice for a stopped agent.
    private func doubleClicked(_ row: LeoAgentRow, modifierFlags: NSEvent.ModifierFlags, from origin: LeoWindowID?) {
        if modifierFlags.contains(.option) {
            go(to: row, from: origin, disposition: .newWindow)
        } else if modifierFlags.contains(.command) {
            go(to: row, from: origin, disposition: .content)
        }
    }

    func fenceInFlightFocusReports() {
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
