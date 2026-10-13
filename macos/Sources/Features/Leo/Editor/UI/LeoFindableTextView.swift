import AppKit

/// A text view that answers the app's Find menu. Edit ▸ Find ▸ Find…, Find
/// Next, Find Previous and Use Selection for Find send `find:`, `findNext:`,
/// `findPrevious:` and `selectionForFind:` (Ghostty's terminal search), which
/// an `NSTextView` doesn't implement: its find bar answers only
/// `performTextFinderAction:`. Unanswered, the message climbs to the window
/// controller and opens a search on a terminal nobody is looking at. So
/// these forward to the text view's own find bar.
class LeoFindableTextView: NSTextView {
    @objc func find(_ sender: Any?) { perform(.showFindInterface) }
    @objc func findNext(_ sender: Any?) { perform(.nextMatch) }
    @objc func findPrevious(_ sender: Any?) { perform(.previousMatch) }
    @objc func selectionForFind(_ sender: Any?) { perform(.setSearchString) }

    private func perform(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
    }
}
