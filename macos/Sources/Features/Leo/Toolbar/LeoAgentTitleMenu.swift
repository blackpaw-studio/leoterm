import AppKit

/// The title item's pull-down. It rebuilds its items from
/// `LeoAgentTitleMenuItems` each time it opens; every command is the Agents
/// menu's own action aimed at the window's own `TerminalController`, which
/// validates it (the same validators as the menu bar's: one implementation).
/// The target is explicit: a nil target resolves through whichever view is
/// first responder (the Chat pane, say), and left every item disabled there. Move To's list is filled by
/// `LeoAgentsMenuController`, which fills the menu bar's.
@MainActor
final class LeoAgentTitleMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Agent")
    private let context: () -> LeoAgentTitleMenuItems.Context
    private let fileExists: (String) -> Bool
    /// What the items act on; `NSMenuItem.target` is weak, so it is read each time the menu rebuilds.
    private let target: () -> AnyObject?

    init(
        target: @escaping () -> AnyObject?, context: @escaping () -> LeoAgentTitleMenuItems.Context,
        fileExists: @escaping (String) -> Bool
    ) {
        self.target = target
        self.context = context
        self.fileExists = fileExists
        super.init()
        menu.delegate = self
        menu.autoenablesItems = true
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuild()
        LeoAgentsMenuController.shared.menuNeedsUpdate(menu)
    }

    private func rebuild() {
        menu.removeAllItems()
        for entry in LeoAgentTitleMenuItems.entries(for: context(), fileExists: fileExists) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .command(let item):
                menu.addItem(makeItem(item))
            }
        }
    }

    private func makeItem(_ item: LeoAgentTitleMenuItems.Item) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.title, action: Self.action(for: item.command), keyEquivalent: "")
        menuItem.target = target()
        if item.command == .moveTo {
            menuItem.identifier = LeoAgentsMenuController.moveToItemIdentifier
            menuItem.submenu = NSMenu(title: item.title)
        }
        return menuItem
    }

    /// The Agents menu's action for each command.
    static func action(for command: LeoAgentTitleMenuItems.Command) -> Selector {
        switch command {
        case .start: #selector(TerminalController.startSelectedLeoAgent(_:))
        case .stop: #selector(TerminalController.stopSelectedLeoAgent(_:))
        case .restart: #selector(TerminalController.restartSelectedLeoAgent(_:))
        case .revealWorkspace: #selector(TerminalController.revealLeoWorkspaceInFinder(_:))
        case .copyWorkspacePath: #selector(TerminalController.copyLeoWorkspacePath(_:))
        case .viewLogs: #selector(TerminalController.viewLogsForSelectedLeoAgent(_:))
        case .moveTo: #selector(TerminalController.moveSelectedLeoAgent(_:))
        case .rename: #selector(TerminalController.renameSelectedLeoAgent(_:))
        case .appearance: #selector(TerminalController.showLeoAgentAppearance(_:))
        case .openInNewWindow: #selector(TerminalController.openSelectedLeoAgentInNewWindow(_:))
        }
    }
}
