import Foundation

/// Pure decision for `TerminalController.surfaceTreeDidChange`'s
/// empty-tree-closes-window guard, extracted so it's unit-testable without a
/// real `TerminalController`/`NSWindow` (which this codebase has no way to
/// construct in a unit test -- AppKit glue is verified by build + laptop
/// acceptance instead).
///
/// An empty tree closes the window exactly like upstream always has --
/// UNLESS this is a still-unfilled Leo placeholder window
/// (`TerminalController.leoIsUnfilledPlaceholder`), whose empty tree is
/// intentional (shown via `LeoPlaceholderView`) rather than "everything
/// closed". Narrowly scoped to that flag, not just "has a Leo session":
/// a normal Leo window whose last surface/tab the user closed must still
/// close, especially with `quit-after-last-window-closed`.
///
/// B-004: nor does it close while the window's editor has unsaved edits
/// -- a tree that empties without asking (the terminal's process exited)
/// leaves the editor beside the start screen instead of dropping them.
enum LeoPlaceholderCloseDecision {
    static func shouldCloseOnEmptyTree(isEmpty: Bool, isUnfilledPlaceholder: Bool, hasUnsavedEdits: Bool) -> Bool {
        isEmpty && !isUnfilledPlaceholder && !hasUnsavedEdits
    }
}
