import AppKit

/// Agents ▸ Pin Agent (⌥⌘P) and Agents ▸ Sort By (B-010). The pin acts on
/// the sidebar's selection, like the other agent commands; the row's
/// context menu offers the same toggle.
extension TerminalController {
    @IBAction func toggleSelectedLeoAgentPin(_ sender: Any?) {
        guard leoSession != nil, let runtime = leoRuntime, let row = selectedLeoRow else { return }
        runtime.model.togglePin(row.id)
    }

    @IBAction func sortLeoAgentsByLastActivity(_ sender: Any?) { leoRuntime?.model.setSortOrder(.lastActivity) }

    @IBAction func sortLeoAgentsByName(_ sender: Any?) { leoRuntime?.model.setSortOrder(.name) }

    func validateLeoPinMenuItem(_ item: NSMenuItem) -> Bool {
        let isPinned = selectedLeoRow.map { leoRuntime?.model.isPinned($0.id) ?? false } ?? false
        item.title = LeoMenuCommands.pinToggleTitle(isPinned: isPinned)
        return LeoMenuCommands.canTogglePin(selectedLeoAgentContext)
    }

    func validateLeoSortMenuItem(_ item: NSMenuItem, order: LeoSidebarSortOrder) -> Bool {
        item.state = leoRuntime?.model.preferences.sortOrder == order ? .on : .off
        return leoSession != nil
    }
}
