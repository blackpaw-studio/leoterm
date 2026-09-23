import AppKit

/// Closing tabs and windows with unsaved editor edits (B-004). Every close
/// path in `TerminalController` comes through here: one that can ask goes
/// through `LeoUnsavedEditorsGate` first; one that can't keeps the tab.
extension TerminalController {
    /// Whether this tab's editor has unsaved edits.
    var leoHasUnsavedEdits: Bool {
        leoSession.map { LeoUnsavedEditorsGate.hasUnsavedEdits($0.editor) } ?? false
    }

    /// Leo: a close of `windows` (tabs) that can ask. `true` when the gate
    /// took it over: Save / Don't Save / Cancel for each editor with
    /// unsaved edits, then `retry` -- or the close is dropped.
    static func leoDeferClose(of windows: [NSWindow], retry: @escaping @MainActor () -> Void) -> Bool {
        guard let runtime = (NSApp.delegate as? AppDelegate)?.leoRuntime else { return false }
        let sessions = windows.compactMap { ($0.windowController as? TerminalController)?.leoSession }
        return runtime.unsavedEditors.deferClose(of: sessions.map(runtime.editorEntry(for:))) { if $0 { retry() } }
    }

    /// Leo: ⌘W with focus in the terminal. When it would close the tab
    /// (it's the only split), unsaved editor edits are asked about first:
    /// `true` when the gate took it over.
    func leoDeferCloseOfLastSplit(retry: @escaping @MainActor () -> Void) -> Bool {
        guard !surfaceTree.isSplit, let window else { return false }
        return Self.leoDeferClose(of: [window], retry: retry)
    }

    /// Leo: a close that can't ask first -- the terminal's process exited,
    /// AppleScript, undo or redo, a drag took the last split -- never drops
    /// unsaved editor edits. The tab stays with its editor, and the start
    /// screen replaces its terminal (`LeoPlaceholderCloseDecision` keeps
    /// the window). `true` when it kept the tab.
    func leoKeepForUnsavedEdits() -> Bool {
        guard leoHasUnsavedEdits else { return false }
        if !surfaceTree.isEmpty { surfaceTree = .init() }
        leoSession?.editorPane?.focusText()
        return true
    }

    /// Leo: closing the window (all its tabs) without asking closes the
    /// tabs without unsaved editor edits and keeps the rest. `true` when
    /// it kept any (and closed the others).
    func leoCloseWindowKeepingUnsavedEdits() -> Bool {
        let windows = window.map { $0.tabGroup?.windows ?? [$0] } ?? []
        let tabs = windows.compactMap { $0.windowController as? TerminalController }
        guard tabs.contains(where: \.leoHasUnsavedEdits) else { return false }
        for tab in tabs where !tab.leoKeepForUnsavedEdits() {
            tab.closeTabImmediately()
        }
        return true
    }
}
