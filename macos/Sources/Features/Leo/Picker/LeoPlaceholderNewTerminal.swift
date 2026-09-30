import AppKit

/// B-069: the start screen's "New Terminal" button. It is File ▸ New
/// Terminal (⌘T) itself, not a copy: it sends that menu item's action,
/// so the window makes and selects a Terminals row exactly as ⌘T does
/// (D-099, D-125).
enum LeoPlaceholderNewTerminal {
    static let title = LeoWindowTabbing.newTerminalTitle
    /// The tooltip: the menu item's shortcut (D-128's pattern).
    static let help = LeoWindowTabbing.newTerminalShortcut
    /// File ▸ New Terminal's action.
    static let action = #selector(TerminalController.newTab(_:))

    /// Sends ⌘T's action to `target` -- the button's own window's
    /// controller, so the row lands in the window that was clicked even if
    /// another window is key. With no target it goes up the key window's
    /// responder chain, as the menu item's nil-targeted action does.
    /// Returns whether anything handled it.
    @MainActor @discardableResult
    static func send(to target: AnyObject?) -> Bool {
        NSApp.sendAction(action, to: target, from: nil)
    }
}
