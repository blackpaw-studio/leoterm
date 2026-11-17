import AppKit

/// The pane's stack, which offers key equivalents to the pane before its
/// subviews (the page included) see them.
final class LeoAgentBrowserPaneStack: NSStackView {
    var onKeyEquivalent: (NSEvent) -> Bool = { _ in false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }
}

/// Find in page (B-407). The menu's Find items reach these through the
/// responder chain while focus is anywhere in the pane (the page, the address
/// bar, the find field); with the terminal or the editor focused they never
/// get here, so those keep their own find. ⌘F, ⌘G and ⌘⇧G are claimed by the
/// pane's stack under the same condition. Finding reads the page, so none of
/// it counts as the user's input to the agent's browser.
extension LeoAgentBrowserPaneViewController: NSMenuItemValidation {
    /// What the key equivalent asks for: ⌘F, ⌘G or ⌘⇧G; nil for any other key.
    static func findAction(for event: NSEvent) -> Selector? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("f", [.command]): return #selector(find(_:))
        case ("g", [.command]): return #selector(findNext(_:))
        case ("g", [.command, .shift]): return #selector(findPrevious(_:))
        default: return nil
        }
    }

    /// True when `responder` is in this pane: a view in it, or the field
    /// editor of a text field in it.
    func ownsFindFocus(_ responder: NSResponder?) -> Bool {
        Self.responder(responder, isIn: view)
    }

    private static func responder(_ responder: NSResponder?, isIn container: NSView) -> Bool {
        let responderView = (responder as? NSText)?.delegate as? NSView ?? responder as? NSView
        return responderView?.isDescendant(of: container) ?? false
    }

    func performFindKeyEquivalent(_ event: NSEvent) -> Bool {
        guard ownsFindFocus(view.window?.firstResponder), let action = Self.findAction(for: event) else { return false }
        perform(action, with: nil)
        return true
    }

    func wireFind() {
        findBar.onQueryChange = { [weak self] in self?.findController.setQuery($0) }
        findBar.onStep = { [weak self] in self?.findController.step($0) }
        findBar.onClose = { [weak self] in self?.findHide(nil) }
        findController.onChange = { [weak self] in self?.refreshFindBar() }
    }

    func refreshFindBar() {
        findBar.isHidden = !findController.isShown
        findBar.update(query: findController.query, label: findController.labelText)
    }

    @objc func find(_ sender: Any?) {
        findController.show()
        findBar.focusField()
    }

    @objc func findNext(_ sender: Any?) {
        stepFind(.next)
    }

    @objc func findPrevious(_ sender: Any?) {
        stepFind(.previous)
    }

    /// Esc, Done and Edit ▸ Hide Find Bar: the marks go and focus returns to
    /// the page when it was in the bar.
    @objc func findHide(_ sender: Any?) {
        if ownsFindBarFocus, let page = model.source.activeView {
            view.window?.makeFirstResponder(page)
        }
        findController.hide()
    }

    @objc func selectionForFind(_ sender: Any?) {
        Task { await findController.useSelection() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(findHide(_:)) ? findController.isShown : true
    }

    private func stepFind(_ direction: LeoFindDirection) {
        let wasShown = findController.isShown
        findController.step(direction)
        if !wasShown { findBar.focusField() }
    }

    private var ownsFindBarFocus: Bool {
        Self.responder(view.window?.firstResponder, isIn: findBar)
    }
}
