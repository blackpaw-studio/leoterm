import AppKit
import SwiftUI

/// B-080: a menu item's shortcut as shown to users ("⇧⌘N"), read off the
/// item itself. AppDelegate syncs the items' key equivalents from the
/// Ghostty config's keybinds, so the item is the one source that is never
/// stale; a hint built from a constant would lie after a rebind.
@MainActor enum LeoMenuShortcutHint {
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    /// AppKit's F1…F35 key equivalents: consecutive private-use characters.
    private static let functionKeys = NSF1FunctionKey...NSF35FunctionKey

    /// The item's shortcut in menu notation, or nil when it has none or its
    /// key can't be spelled (a private-use key with no Mac key cap such as
    /// Insert, a bare control character): no hint beats a wrong one.
    static func text(for item: NSMenuItem?) -> String? {
        guard let item, item.keyEquivalent.count == 1, let character = item.keyEquivalent.first,
              let key = character.lowercased().first else { return nil }
        var modifiers = item.keyEquivalentModifierMask.intersection(shortcutModifiers)
        // AppKit reads an upper-case key equivalent as ⇧ + the key.
        if character.isUppercase { modifiers.insert(.shift) }
        let shortcut = KeyboardShortcut(KeyEquivalent(key), modifiers: EventModifiers(nsFlags: modifiers))
        if let functionKey = functionKeyName(key) {
            // B-104: spelled as the menu bar does ("⌘F1"), modifiers first.
            return (shortcut.keyList.dropLast() + [functionKey]).joined()
        }
        let text = shortcut.description
        return text.unicodeScalars.allSatisfy(isSpellable) ? text : nil
    }

    /// "F1"…"F35" for AppKit's function-key characters, else nil.
    private static func functionKeyName(_ key: Character) -> String? {
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
              functionKeys.contains(Int(scalar.value)) else { return nil }
        return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
    }

    /// The first item in `menu` (submenus included) whose action is
    /// `action`, preferring one that carries a shortcut. Looked up by action,
    /// not key, so a rebind can't hide the item.
    static func menuItem(action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        let items = allItems(in: menu).filter { $0.action == action }
        return items.first { !$0.keyEquivalent.isEmpty } ?? items.first
    }

    private static func allItems(in menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + allItems(in: $0.submenu) }
    }

    private static func isSpellable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .privateUse, .unassigned: false
        default: true
        }
    }
}

/// The start screen's and the sidebar button bar's shortcut tooltips (New
/// Terminal, Choose Agent…, the disconnected tooltip's Reconnect, Quick
/// Terminal). AppDelegate calls `sync(menu:)` after every menu-shortcut
/// sync (launch, config reload, keyboard-layout change); the views observe
/// it, so an open start screen or sidebar follows a reload.
@MainActor final class LeoShortcutHints: ObservableObject {
    static let newTerminalAction = #selector(TerminalController.newTab(_:))
    static let chooseAgentAction = #selector(TerminalController.chooseLeoAgent(_:))
    static let quickTerminalAction = #selector(AppDelegate.toggleQuickTerminal(_:))
    static let reconnectAction = #selector(TerminalController.reconnectLeo(_:))

    /// Nil until the first sync, and whenever the item has no shortcut.
    @Published private(set) var newTerminal: String?
    @Published private(set) var chooseAgent: String?
    /// View ▸ Quick Terminal's: ships unbound (its keybind is global).
    @Published private(set) var quickTerminal: String?
    /// Agents ▸ Reconnect's (⇧⌘R in the xib): named by the disconnected
    /// Choose Agent… tooltip (B-104).
    @Published private(set) var reconnect: String?

    func sync(menu: NSMenu?) {
        let newTerminal = Self.hint(for: Self.newTerminalAction, in: menu)
        let chooseAgent = Self.hint(for: Self.chooseAgentAction, in: menu)
        let quickTerminal = Self.hint(for: Self.quickTerminalAction, in: menu)
        let reconnect = Self.hint(for: Self.reconnectAction, in: menu)
        // Publish only real changes: every reload re-syncs.
        if newTerminal != self.newTerminal { self.newTerminal = newTerminal }
        if chooseAgent != self.chooseAgent { self.chooseAgent = chooseAgent }
        if quickTerminal != self.quickTerminal { self.quickTerminal = quickTerminal }
        if reconnect != self.reconnect { self.reconnect = reconnect }
    }

    private static func hint(for action: Selector, in menu: NSMenu?) -> String? {
        LeoMenuShortcutHint.text(for: LeoMenuShortcutHint.menuItem(action: action, in: menu))
    }
}
