import AppKit

/// Menu bar actions for the window's editor pane (B-004). Save, Reload
/// from Disk and Keep My Version act on the window's pane wherever focus
/// is in the window; ⌘W closes the pane only while it has focus (see
/// `LeoEditorPaneViewController.close(_:)`).
extension TerminalController {
    private var leoEditor: LeoEditorTabs? { leoSession?.editor }

    /// Agents ▸ Open File in Editor… (⇧⌘O): a path relative to the focused
    /// agent's workspace.
    @IBAction func openFileInLeoEditor(_ sender: Any?) {
        guard let leoSession, let runtime = leoRuntime, let window else { return }
        let agent = runtime.editorContext(in: self)
        Task {
            guard let text = await LeoEditorAlerts.askForPath(for: agent, on: window) else { return }
            await runtime.openInEditor(text, for: agent, in: leoSession, window: window)
        }
    }

    /// Agents ▸ Focus Editor / Focus Terminal (⌥⌘E).
    @IBAction func toggleLeoEditorFocus(_ sender: Any?) {
        guard let pane = leoSession?.editorPane, leoEditor?.isOpen == true else { return }
        if pane.hasFocus, let focusedSurface {
            Ghostty.moveFocus(to: focusedSurface)
        } else {
            pane.focusText()
        }
    }

    /// File ▸ Save (⌘S). A blocked save (a banner is up, or the file is
    /// read-only) beeps; failures and conflicts show in the pane's banner.
    @IBAction func saveDocument(_ sender: Any?) {
        guard let document = leoEditor?.document else { return }
        Task {
            switch await document.save() {
            case .needsResolution, .readOnly: NSSound.beep()
            case .saved, .unchanged, .conflict, .failed: break
            }
        }
    }

    /// File ▸ Reload from Disk (⌥⌘R), while the file changed on disk.
    @IBAction func reloadLeoEditorFromDisk(_ sender: Any?) {
        guard let document = leoEditor?.document else { return }
        Task { await document.reload() }
    }

    /// File ▸ Keep My Version (⌥⌘K), while the file changed or was deleted.
    @IBAction func keepLeoEditorVersion(_ sender: Any?) {
        leoEditor?.document?.keepMine()
    }

    /// Returns nil for items that aren't the editor's.
    func validateLeoEditorMenuItem(_ item: NSMenuItem) -> Bool? {
        let document = leoEditor?.document
        switch item.action {
        case #selector(openFileInLeoEditor(_:)):
            return leoSession != nil
        case #selector(toggleLeoEditorFocus(_:)):
            item.title = leoSession?.editorPane?.hasFocus == true ? "Focus Terminal" : "Focus Editor"
            return leoEditor?.isOpen == true
        case #selector(saveDocument(_:)):
            return document.map { !$0.isReadOnly } ?? false
        case #selector(reloadLeoEditorFromDisk(_:)):
            return document?.diskState == .changed
        case #selector(keepLeoEditorVersion(_:)):
            return document.map { $0.diskState != .inSync } ?? false
        default:
            return nil
        }
    }
}
