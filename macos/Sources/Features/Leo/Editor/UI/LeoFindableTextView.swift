import AppKit

/// A text view that answers the app's Find menu. Edit ▸ Find ▸ Find…, Find
/// Next, Find Previous, Use Selection for Find and Hide Find Bar send
/// `find:`, `findNext:`, `findPrevious:`, `selectionForFind:` and `findHide:`
/// (Ghostty's terminal search), which an `NSTextView` doesn't implement: its
/// find bar answers only `performTextFinderAction:`. Unanswered, the message
/// climbs to the window controller and searches a terminal nobody is looking
/// at. So these forward to the text view's own find bar.
///
/// ⌘F, ⌘G and ⇧⌘G are handled here too, not left to the menu. They are
/// `performable` terminal bindings, which Ghostty leaves out of its reverse
/// lookup, so Edit ▸ Find has no key equivalent and the keystroke would reach
/// nothing but a focused terminal surface.
///
/// Once the find bar's search field has focus, the responder chain runs
/// through the bar and the scroll view, not through this text view, so the
/// window controller asks `owner(of:)` first (`BaseTerminalController`).
class LeoFindableTextView: NSTextView {
    /// The find-capable text view whose find the Find menu should drive, given
    /// the window's first responder: the text view itself, or the field
    /// editor of the search field in its find bar. Nil for anything else
    /// (a terminal, the composer, the sidebar filter).
    static func owner(of responder: NSResponder?) -> LeoFindableTextView? {
        if let textView = responder as? LeoFindableTextView { return textView }
        guard let editor = responder as? NSText, editor.isFieldEditor, let field = editor.delegate as? NSView else { return nil }
        return sequence(first: field, next: \.superview)
            .compactMap { ($0 as? NSScrollView)?.documentView as? LeoFindableTextView }
            .first
    }

    /// The find action a keystroke stands for, by the standard macOS shortcuts.
    static func finderAction(for event: NSEvent) -> NSTextFinder.Action? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("f", [.command]): return .showFindInterface
        case ("g", [.command]): return .nextMatch
        case ("g", [.command, .shift]): return .previousMatch
        default: return nil
        }
    }

    /// Only with this text view, or its find bar's field, holding the keyboard:
    /// a key equivalent is offered to every view in the window, not just the
    /// first responder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let action = Self.finderAction(for: event), Self.owner(of: window?.firstResponder) === self else {
            return super.performKeyEquivalent(with: event)
        }
        perform(action)
        return true
    }

    @objc func find(_ sender: Any?) { perform(.showFindInterface) }
    @objc func findNext(_ sender: Any?) { perform(.nextMatch) }
    @objc func findPrevious(_ sender: Any?) { perform(.previousMatch) }
    @objc func selectionForFind(_ sender: Any?) { perform(.setSearchString) }
    @objc func findHide(_ sender: Any?) { perform(.hideFindInterface) }

    /// Hide Find Bar is only live while the bar is up.
    var isFindBarShown: Bool { enclosingScrollView?.isFindBarVisible == true }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(findHide(_:)) { return isFindBarShown }
        return super.validateMenuItem(item)
    }

    private func perform(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
    }
}
