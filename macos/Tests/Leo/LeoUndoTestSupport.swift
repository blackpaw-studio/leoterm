import AppKit

@testable import Ghostty

extension UndoManager {
    /// Drops every action a test's ⌘Z could replay from an earlier test:
    /// the app has one undo manager, so an earlier test's Close Window or
    /// Close Tab (targeting `Ghostty.App`) could reopen a window holding
    /// live shells, and a still-open window's tree edits could replay.
    @MainActor func leoRemoveActionsTestsCanReplay(ghostty: Ghostty.App) {
        removeAllActions(withTarget: ghostty)
        TerminalController.all.forEach(removeAllActions(withTarget:))
    }
}
