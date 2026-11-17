import AppKit

/// Reopen Closed Tab and Back / Forward (B-408). The History menu's items reach
/// these through the responder chain while focus is anywhere in the pane, as
/// Find does; with the terminal or the editor focused they never get here, so
/// ⌘[ and ⌘] stay Ghostty's split navigation and ⌘⇧T its undo. The pane's
/// stack claims the keys under the same condition. The actions are
/// `browserGoBack:` / `browserGoForward:`, not the web view's own `goBack:`,
/// so the menu can't bypass the user-takes-control step.
extension LeoAgentBrowserPaneViewController {
    /// What the key equivalent asks for: ⌘[, ⌘] or ⌘⇧T; nil for any other key.
    static func historyAction(for event: NSEvent) -> Selector? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("[", [.command]): return #selector(browserGoBack(_:))
        case ("]", [.command]): return #selector(browserGoForward(_:))
        case ("t", [.command, .shift]): return #selector(reopenClosedTab(_:))
        default: return nil
        }
    }

    func performHistoryKeyEquivalent(_ event: NSEvent) -> Bool {
        guard ownsFindFocus(view.window?.firstResponder), let action = Self.historyAction(for: event) else { return false }
        perform(action, with: nil)
        return true
    }

    @objc func browserGoBack(_ sender: Any?) {
        if model.canGoBack { model.goBack() } else { NSSound.beep() }
    }

    @objc func browserGoForward(_ sender: Any?) {
        if model.canGoForward { model.goForward() } else { NSSound.beep() }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        if !model.reopenClosedTab() { NSSound.beep() }
    }

    /// nil for an item that isn't a History item.
    func validateHistoryItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(browserGoBack(_:)): model.canGoBack
        case #selector(browserGoForward(_:)): model.canGoForward
        case #selector(reopenClosedTab(_:)): model.source.canReopenClosedTab
        default: nil
        }
    }
}
