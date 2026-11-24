import AppKit

/// View ▸ Dock Focused Pane Right / Below (⌃⌥⌘→ / ⌃⌥⌘↓, B-439): moves the
/// pane with keyboard focus -- Browser or Files -- to that edge in every
/// window, and keeps focus in it.
extension TerminalController {
    @IBAction func dockFocusedLeoPaneRight(_ sender: Any?) { dockFocusedLeoPane(to: .right) }

    @IBAction func dockFocusedLeoPaneBelow(_ sender: Any?) { dockFocusedLeoPane(to: .below) }

    /// Enables the item for a focused pane and checks the pane's edge now.
    func validateLeoDockMenuItem(_ item: NSMenuItem, edge: LeoDockEdge) -> Bool {
        let state = LeoMenuCommands.dockFocusedPaneItem(
            edge, focused: focusedLeoDockPane, layout: leoSession?.paneDock.layout ?? LeoPaneDockLayout())
        item.state = state.isChecked ? .on : .off
        return state.isEnabled && leoSession?.split?.paneDock != nil
    }

    private var focusedLeoDockPane: LeoDockPane? { LeoPaneDockFocus.pane(for: window?.firstResponder) }

    private func dockFocusedLeoPane(to edge: LeoDockEdge) {
        guard let pane = focusedLeoDockPane, let dock = leoSession?.split?.paneDock else { return }
        dock.move(pane, to: edge)
    }
}
