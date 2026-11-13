import AppKit

/// Agents ▸ Reveal Workspace in Finder and Copy Workspace Path (⌥⌘C): the
/// selected agent's workspace. The title menu and the sidebar's right-click
/// menu offer the same two through `LeoWorkspaceActions`.
extension TerminalController {
    @IBAction func revealLeoWorkspaceInFinder(_ sender: Any?) {
        guard let row = selectedLeoRow, LeoWorkspaceActions.live.reveal(host: row.host, workspace: row.workspace) else {
            return NSSound.beep()
        }
    }

    @IBAction func copyLeoWorkspacePath(_ sender: Any?) {
        guard let row = selectedLeoRow, LeoWorkspaceActions.live.copyPath(workspace: row.workspace) else { return NSSound.beep() }
    }

    /// Returns nil for items that aren't the workspace's.
    func validateLeoWorkspaceMenuItem(_ item: NSMenuItem) -> Bool? {
        let row = selectedLeoRow
        switch item.action {
        case #selector(revealLeoWorkspaceInFinder(_:)):
            guard let row else { return false }
            return LeoAgentTitleMenuItems.canRevealWorkspace(
                host: row.host, workspace: row.workspace, fileExists: LeoWorkspaceActions.live.fileExists)
        case #selector(copyLeoWorkspacePath(_:)):
            return LeoAgentTitleMenuItems.canCopyWorkspacePath(
                row.map { .init(availability: LeoRowActionAvailability(status: $0.status, isPending: false), host: $0.host, workspace: $0.workspace) })
        default:
            return nil
        }
    }
}
