import AppKit

/// What the toolbar's title menu adds to the Agents menu's own commands:
/// Appearance… and Open in New Window (both also in Agents, so every toolbar
/// command is in the menu bar), and the menu's context. Each acts on the
/// agent shown in this window.
extension TerminalController {
    /// What the title menu lists for the selected agent.
    var leoTitleMenuContext: LeoAgentTitleMenuItems.Context {
        let row = selectedLeoRow
        let features = row.flatMap { leoRuntime?.model.features(for: $0.host) }
        return LeoAgentTitleMenuItems.Context(
            agent: row.map { row in
                .init(
                    availability: LeoRowActionAvailability(
                        status: row.status, isPending: leoRuntime?.actions.pendingActions.contains(row.id) ?? false, movedTo: row.movedTo),
                    host: row.host, workspace: row.workspace)
            },
            movesSupported: features?.contains(.agentMove) ?? true,
            appearanceSupported: features?.contains(.agentAppearance) ?? true)
    }

    /// Agents ▸ Appearance…: the editor, as a popover anchored to the title item.
    @IBAction func showLeoAgentAppearance(_ sender: Any?) {
        guard let runtime = leoRuntime, let row = selectedLeoRow, let window = window as? LeoAgentTerminalWindow else { return NSSound.beep() }
        guard let anchor = window.leoToolbar.titleAnchorView ?? window.contentView else { return }
        LeoAgentAppearancePresenter.present(row: row, runtime: runtime, relativeTo: anchor)
    }

    /// Agents ▸ Open in New Window: the sidebar's ⌥-click, as a command.
    @IBAction func openSelectedLeoAgentInNewWindow(_ sender: Any?) {
        guard let leoSession, let runtime = leoRuntime, let row = selectedLeoRow else { return NSSound.beep() }
        runtime.model.requestAttach(row, from: leoSession.id, disposition: .newWindow)
    }

    /// Returns nil for items that aren't these.
    func validateLeoTitleMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(showLeoAgentAppearance(_:)):
            guard let row = selectedLeoRow else { return false }
            return leoRuntime?.model.features(for: row.host).contains(.agentAppearance) ?? false
        case #selector(openSelectedLeoAgentInNewWindow(_:)):
            return LeoMenuCommands.canAttach(selectedLeoAgentContext)
        default:
            return nil
        }
    }
}
