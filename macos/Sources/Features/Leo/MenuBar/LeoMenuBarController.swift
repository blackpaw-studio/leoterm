import AppKit
import LeoKit

/// Renders `LeoMenuBarModel` as an `NSStatusItem` and rebuilds the menu each
/// time it opens (`menuNeedsUpdate`), so it never goes stale. Rendering only:
/// the decisions are `LeoMenuBarModel`'s. Styling is a TDD exception; verify
/// by screenshot.
@MainActor final class LeoMenuBarController: NSObject, NSMenuDelegate {
    private let inputs: () -> LeoMenuBarInputs
    private let perform: (LeoMenuBarAction) -> Void
    private let attach: (LeoAgentRow.ID) -> Void
    private var statusItem: NSStatusItem?

    init(
        inputs: @escaping () -> LeoMenuBarInputs,
        perform: @escaping (LeoMenuBarAction) -> Void,
        attach: @escaping (LeoAgentRow.ID) -> Void
    ) {
        self.inputs = inputs
        self.perform = perform
        self.attach = attach
    }

    var isVisible: Bool { statusItem != nil }

    func setVisible(_ visible: Bool) {
        switch (visible, statusItem) {
        case (true, nil):
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.icon
            item.button?.setAccessibilityLabel("Leo")
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            statusItem = item
        case (false, let item?):
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        default:
            break
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in LeoMenuBarModel.items(inputs()) {
            menu.addItem(menuItem(for: item))
        }
    }

    // MARK: Rendering

    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Leo")
        image?.isTemplate = true
        return image
    }()

    private func menuItem(for item: LeoMenuBarItem) -> NSMenuItem {
        switch item {
        case .separator:
            return .separator()
        case .status(let title, let detail):
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = false
            if let detail {
                if #available(macOS 14.4, *) {
                    menuItem.subtitle = detail
                } else {
                    menuItem.title = "\(title) — \(detail)"
                }
            }
            return menuItem
        case .agents(let title, let isEnabled, let agents):
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = isEnabled
            guard isEnabled else { return menuItem }
            let submenu = NSMenu(title: title)
            submenu.autoenablesItems = false
            for agent in agents { submenu.addItem(agentItem(agent)) }
            menuItem.submenu = submenu
            return menuItem
        case .action(let action, let title, let isEnabled, let isChecked):
            let menuItem = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.isEnabled = isEnabled
            menuItem.state = isChecked ? .on : .off
            menuItem.representedObject = ActionBox(action)
            return menuItem
        }
    }

    private func agentItem(_ agent: LeoMenuBarAgent) -> NSMenuItem {
        let menuItem = NSMenuItem(title: agent.name, action: #selector(attachAgent(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = AgentBox(agent.id)
        menuItem.image = Self.stateImage(for: agent)
        return menuItem
    }

    private static func stateImage(for agent: LeoMenuBarAgent) -> NSImage? {
        let (symbol, color): (String, NSColor) = switch (agent.needsAttention, agent.state) {
        case (true, _): ("exclamationmark.circle.fill", .systemOrange)
        case (_, .running): ("circle.fill", .systemGreen)
        case (_, .starting): ("circle.dotted", .systemYellow)
        case (_, .stopped): ("circle", .secondaryLabelColor)
        case (_, .other): ("questionmark.circle", .secondaryLabelColor)
        }
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        perform(box.action)
    }

    @objc private func attachAgent(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? AgentBox else { return }
        attach(box.id)
    }

    private final class ActionBox: NSObject {
        let action: LeoMenuBarAction
        init(_ action: LeoMenuBarAction) { self.action = action }
    }

    private final class AgentBox: NSObject {
        let id: LeoAgentRow.ID
        init(_ id: LeoAgentRow.ID) { self.id = id }
    }
}
