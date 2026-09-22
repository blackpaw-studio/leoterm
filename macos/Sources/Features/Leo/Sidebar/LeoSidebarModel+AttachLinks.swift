import Foundation

/// B-006: the sidebar selection follows the focused attach surface, and a
/// click on a row whose agent already has a live attach brings it forward.
extension LeoSidebarModel {
    /// Selects the focused agent's row. Focus leaving every attachment, or
    /// landing on an agent this sidebar isn't showing (another host), keeps
    /// the current selection rather than inventing one.
    func receiveAttachLinks(_ links: LeoAttachLinkState) {
        attachLinks = links
        guard let focused = links.focused, focused != selection,
              snapshot.rows.contains(where: { $0.id == focused }) else { return }
        selection = focused
    }

    func tabCount(for id: LeoAgentRow.ID) -> Int { attachLinks.tabCount(for: id) }

    /// A single click. Rows without a live attach keep plain selection.
    func rowClicked(_ row: LeoAgentRow) {
        guard tabCount(for: row.id) > 0 else { return }
        focusExistingRequested(row)
    }
}
