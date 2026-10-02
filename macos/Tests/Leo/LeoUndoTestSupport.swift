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

    /// Runs `body` as an undo group of its own, as a typed command's event
    /// is. The test host's busy run loop never ends the group
    /// `groupsByEvent` opens, so two steps would otherwise share one and
    /// ⌘Z would undo both at once; nested inside it instead, each step is
    /// its own group, which `leoUndoLastGroup` undoes alone.
    @MainActor func leoInOwnUndoGroup<T>(_ body: () throws -> T) rethrows -> T {
        beginUndoGrouping()
        defer { endUndoGrouping() }
        return try body()
    }

    /// ⌘Z of the last group `leoInOwnUndoGroup` made, whether or not an
    /// event's group is still open around it.
    @MainActor func leoUndoLastGroup() {
        if groupingLevel > 0 { undoNestedGroup() } else { undo() }
    }
}
