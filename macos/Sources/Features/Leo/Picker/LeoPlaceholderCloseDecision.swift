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
enum LeoPlaceholderCloseDecision {
    static func shouldCloseOnEmptyTree(isEmpty: Bool, isUnfilledPlaceholder: Bool) -> Bool {
        isEmpty && !isUnfilledPlaceholder
    }
}
