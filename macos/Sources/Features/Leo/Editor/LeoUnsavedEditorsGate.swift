import Foundation

/// The one gate every close of a tab, a window or the app goes through,
/// so unsaved editor edits are never dropped. A close that can ask (Close
/// Tab, Close Window, ⌘W, Close Other Tabs, Close All Windows, Quit) asks
/// about each editor with unsaved edits in turn -- Save / Don't Save /
/// Cancel, on its window, brought forward first -- and is retried once
/// every one is resolved; Cancel (or a Save that can't go through) drops
/// it. A close that can't ask keeps the tab instead: see
/// `TerminalController.leoKeepForUnsavedEdits()`.
@MainActor final class LeoUnsavedEditorsGate {
    struct Entry {
        let editor: LeoEditorPaneModel
        /// Brings the editor's window forward, so its sheet is seen.
        let bringForward: @MainActor () -> Void
    }

    /// While a prompt is up. One at a time: a close with unsaved edits
    /// asked for meanwhile (⌘W twice, ⌘Q during Close Tab) is dropped, not
    /// queued -- the user is already answering. One with nothing unsaved
    /// goes ahead.
    private(set) var isAsking = false

    static func hasUnsavedEdits(_ editor: LeoEditorPaneModel) -> Bool {
        editor.document?.isDirty == true
    }

    /// `true` when the gate took the close over: some editors have unsaved
    /// edits (`retry` runs once all are resolved, unless a prompt is
    /// already up). `false`: nothing to ask, so the close goes ahead now.
    func deferClose(of entries: [Entry], retry: @escaping @MainActor () -> Void) -> Bool {
        let unsaved = entries.filter { Self.hasUnsavedEdits($0.editor) }
        guard !unsaved.isEmpty else { return false }
        guard !isAsking else { return true }
        isAsking = true
        Task {
            let resolved = await resolve(unsaved)
            isAsking = false
            if resolved { retry() }
        }
        return true
    }

    /// Asks about each editor with unsaved edits in turn (closing it on
    /// Save or Don't Save). `false` at the first Cancel or failed Save,
    /// leaving that editor and the rest as they are.
    func resolve(_ entries: [Entry]) async -> Bool {
        for entry in entries where Self.hasUnsavedEdits(entry.editor) {
            entry.bringForward()
            guard await entry.editor.close() else { return false }
        }
        return true
    }
}
