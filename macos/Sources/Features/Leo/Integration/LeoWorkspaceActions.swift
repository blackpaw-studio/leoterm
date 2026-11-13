import AppKit
import LeoKit

/// Reveal Workspace in Finder and Copy Workspace Path, with Finder, the
/// pasteboard and the file check injected. The menu bar, the title menu and
/// the sidebar's right-click menu all call this one implementation; the
/// enablement rules are `LeoAgentTitleMenuItems.canRevealWorkspace` and
/// `canCopyWorkspacePath`.
struct LeoWorkspaceActions {
    var reveal: (URL) -> Void
    var copy: (String) -> Void
    var fileExists: (String) -> Bool

    /// The real Finder, general pasteboard and file system.
    @MainActor static let live = LeoWorkspaceActions(
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        copy: { path in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(path, forType: .string)
        },
        fileExists: { FileManager.default.fileExists(atPath: $0) })

    /// Shows the workspace in Finder. False (and nothing happens) for a
    /// remote agent, whose files aren't on this Mac, or a path that is gone.
    @discardableResult
    func reveal(host: LeoHostID, workspace: String?) -> Bool {
        guard LeoAgentTitleMenuItems.canRevealWorkspace(host: host, workspace: workspace, fileExists: fileExists), let workspace else {
            return false
        }
        reveal(URL(fileURLWithPath: workspace))
        return true
    }

    /// Puts the workspace path on the pasteboard as its host reports it.
    @discardableResult
    func copyPath(workspace: String?) -> Bool {
        guard let workspace, !workspace.isEmpty else { return false }
        copy(workspace)
        return true
    }
}
