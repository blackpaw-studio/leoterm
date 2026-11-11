import AppKit
import LeoKit

/// A plugin view from the row's context menu or the toolbar menu: shown in
/// the row's own pane, in the window that ends up showing the row.
extension TerminalController {
    /// Shows the row, then `entry`'s view on it. Beeps when no plugin system is attached.
    func openLeoPluginView(_ entry: LeoPluginViewEntry, forRow row: LeoAgentRow) {
        guard let leoSession, let router = leoRuntime?.rowPaneRouter else { return }
        let agent = LeoPluginAgentRef(machine: row.host.displayName, name: row.name)
        Task {
            guard let (destination, _) = await router.pane(for: row, from: leoSession) else { return }
            if !destination.panes.openPluginView(LeoPluginViewRef(entry: entry, agent: agent), for: .agent(row.identity)) { NSSound.beep() }
        }
    }
}
