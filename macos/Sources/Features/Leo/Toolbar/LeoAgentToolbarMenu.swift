import AppKit

/// What "Show Messages ▸" lists: All Messages, then the agent's known
/// tasks, with the chat's current filter checked. Pure.
enum LeoMessagesFilterMenu {
    struct Entry: Equatable {
        let title: String
        /// The task to filter to; nil is "All Messages".
        let task: String?
        let isChecked: Bool
    }

    static let allMessagesTitle = "All Messages"

    /// A filter whose task is no longer known stays listed, so it can be seen and cleared.
    static func entries(knownTasks: Set<String>, filter: String?) -> [Entry] {
        let tasks = knownTasks.union(filter.map { [$0] } ?? []).sorted()
        return [Entry(title: allMessagesTitle, task: nil, isChecked: filter == nil)]
            + tasks.map { Entry(title: $0, task: $0, isChecked: $0 == filter) }
    }
}

/// The toolbar's "⋯" menu: Interrupt, Compact Context and Clear, which are
/// the Agents menu's own actions with the same titles and shortcuts (read
/// from the live menu, so they never drift), then "Show Messages ▸" over the
/// chat's task filter.
///
/// The control items have no target, so they go down the responder chain
/// like the menu bar's and validate through `TerminalController`. A toolbar
/// menu is never the main menu, so a shortcut fires once, from the menu bar.
@MainActor
final class LeoAgentToolbarMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    /// The chat's task filter, for "Show Messages ▸".
    struct Messages {
        var knownTasks: () -> Set<String>
        var filter: () -> String?
        var hasAgent: () -> Bool
        /// Filters the chat to a task (nil: all messages).
        var select: (String?) -> Void
    }

    static let controlActions: [Selector] = [
        #selector(TerminalController.interruptSelectedLeoAgent(_:)),
        #selector(TerminalController.compactSelectedLeoAgent(_:)),
        #selector(TerminalController.clearSelectedLeoAgent(_:)),
    ]
    private static let fallbackTitles = ["Interrupt", "Compact Context", "Clear Conversation…"]
    private static let showMessagesTitle = "Show Messages"

    let menu = NSMenu(title: "More")
    private let mainMenu: () -> NSMenu?
    private let messages: Messages
    private let controlItems: [NSMenuItem]
    private let messagesItem: NSMenuItem
    private let messagesMenu = NSMenu(title: showMessagesTitle)

    init(mainMenu: @escaping () -> NSMenu?, messages: Messages) {
        self.mainMenu = mainMenu
        self.messages = messages
        controlItems = zip(Self.controlActions, Self.fallbackTitles).map { action, title in
            NSMenuItem(title: title, action: action, keyEquivalent: "")
        }
        messagesItem = NSMenuItem(title: Self.showMessagesTitle, action: #selector(noteSubmenuOnly(_:)), keyEquivalent: "")
        super.init()
        messagesItem.target = self
        messagesItem.submenu = messagesMenu
        menu.delegate = self
        messagesMenu.delegate = self
        messagesMenu.autoenablesItems = false
        controlItems.forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(messagesItem)
        refreshControlItems()
        rebuildMessagesMenu()
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            refreshControlItems()
            messagesItem.isEnabled = messages.hasAgent()
        } else if menu === messagesMenu {
            rebuildMessagesMenu()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem === messagesItem ? messages.hasAgent() : true
    }

    // MARK: Items

    /// Copies each control item's title and shortcut from the live Agents menu.
    private func refreshControlItems() {
        for item in controlItems {
            guard let action = item.action, let live = Self.findItem(for: action, in: mainMenu()) else { continue }
            item.title = live.title
            item.keyEquivalent = live.keyEquivalent
            item.keyEquivalentModifierMask = live.keyEquivalentModifierMask
        }
    }

    private static func findItem(for action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let found = findItem(for: action, in: item.submenu) { return found }
        }
        return nil
    }

    private func rebuildMessagesMenu() {
        messagesMenu.removeAllItems()
        for entry in LeoMessagesFilterMenu.entries(knownTasks: messages.knownTasks(), filter: messages.filter()) {
            let item = NSMenuItem(title: entry.title, action: #selector(pickMessages(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.task
            item.state = entry.isChecked ? .on : .off
            messagesMenu.addItem(item)
            if entry.task == nil { messagesMenu.addItem(.separator()) }
        }
    }

    @objc private func pickMessages(_ sender: NSMenuItem) {
        messages.select(sender.representedObject as? String)
    }

    /// "Show Messages" only opens its submenu; the action exists so the item is validated.
    @objc private func noteSubmenuOnly(_ sender: NSMenuItem) {}
}
