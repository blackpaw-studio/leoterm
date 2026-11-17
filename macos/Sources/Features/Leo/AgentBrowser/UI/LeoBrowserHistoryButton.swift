import AppKit

/// Back or Forward with its history behind it (B-408): a quick click goes one
/// page, and right-click or press-and-hold lists the tab's pages in that
/// direction, nearest first, to jump to one. VoiceOver reaches the list with
/// Show Menu.
final class LeoBrowserHistoryButton: NSButton {
    /// How long a press must last to open the list instead of clicking.
    static let holdDelay: TimeInterval = 0.4
    static let titleLimit = 60

    enum Press: Equatable {
        /// Released inside before the delay.
        case click
        /// Held past the delay, or dragged.
        case hold
        /// Released outside.
        case cancel
    }

    /// The pages to list, nearest first.
    var history: () -> [LeoBrowserHistoryEntry] = { [] }
    var onSelect: (LeoBrowserHistoryEntry) -> Void = { _ in }
    /// Shows the menu under the button; returns when it closes.
    var present: (NSMenu, LeoBrowserHistoryButton) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }
    /// Follows a press that began with `event` until it is a click, a hold or
    /// cancelled.
    var trackPress: (NSEvent, LeoBrowserHistoryButton) -> Press = LeoBrowserHistoryButton.track

    private var entries: [LeoBrowserHistoryEntry] = []

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isHighlighted = true
        let press = trackPress(event, self)
        isHighlighted = false
        switch press {
        case .click: sendAction(action, to: target)
        case .hold: showHistory()
        case .cancel: break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showHistory()
    }

    override func accessibilityPerformShowMenu() -> Bool {
        showHistory()
        return !entries.isEmpty
    }

    /// Lists the pages; nothing to show when there are none.
    func showHistory() {
        entries = history()
        guard !entries.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(title: Self.menuTitle(for: entry), action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.toolTip = entry.url.absoluteString
            menu.addItem(item)
        }
        present(menu, self)
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard entries.indices.contains(sender.tag) else { return }
        onSelect(entries[sender.tag])
    }

    /// The page's title, or its address when it has none, cut to `titleLimit`.
    static func menuTitle(for entry: LeoBrowserHistoryEntry) -> String {
        let text = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = text.isEmpty ? entry.url.absoluteString : text
        return title.count > titleLimit ? String(title.prefix(titleLimit)) + "…" : title
    }

    private static func track(_ event: NSEvent, _ button: LeoBrowserHistoryButton) -> Press {
        let deadline = Date(timeIntervalSinceNow: holdDelay)
        let next = button.window?.nextEvent(
            matching: [.leftMouseUp, .leftMouseDragged], until: deadline, inMode: .eventTracking, dequeue: true
        )
        guard let next else { return .hold }
        guard next.type == .leftMouseUp else { return .hold }
        return button.bounds.contains(button.convert(next.locationInWindow, from: nil)) ? .click : .cancel
    }
}
