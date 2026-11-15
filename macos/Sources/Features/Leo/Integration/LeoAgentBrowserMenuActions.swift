import AppKit

/// The sidebar row's Open Browser: the agent's browser, made on a blank
/// page when it has none, in front in the row's pane.
extension TerminalController {
    /// Shows the row, then its browser in the window showing it
    /// (`LeoRowPaneRouter`). Beeps when this Mac can't run the browser or
    /// the Agent browser setting is off.
    func openLeoAgentBrowser(forRow row: LeoAgentRow) {
        guard let leoSession, let router = leoRuntime?.rowPaneRouter else { return }
        Task {
            guard let (destination, _) = await router.pane(for: row, from: leoSession) else { return }
            if !destination.panes.openAgentBrowser(for: .agent(row.identity)) { NSSound.beep() }
        }
    }
}
