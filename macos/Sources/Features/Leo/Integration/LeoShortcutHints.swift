import AppKit
import SwiftUI

/// B-080: a menu item's shortcut as shown to users ("⇧⌘N"), read off the
/// item itself. AppDelegate syncs the items' key equivalents from the
/// Ghostty config's keybinds, so the item is the one source that is never
/// stale; a hint built from a constant would lie after a rebind.
enum LeoMenuShortcutHint {
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// The item's shortcut in menu notation, or nil when it has none or its
    /// key can't be spelled (a function key's private-use character, a bare
    /// control character): no hint beats a wrong one.
    static func text(for item: NSMenuItem?) -> String? {
        guard let item, item.keyEquivalent.count == 1, let character = item.keyEquivalent.first,
              let key = character.lowercased().first else { return nil }
        var modifiers = item.keyEquivalentModifierMask.intersection(shortcutModifiers)
        // AppKit reads an upper-case key equivalent as ⇧ + the key.
        if character.isUppercase { modifiers.insert(.shift) }
        let text = KeyboardShortcut(KeyEquivalent(key), modifiers: EventModifiers(nsFlags: modifiers)).description
        return text.unicodeScalars.allSatisfy(isSpellable) ? text : nil
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
/// Terminal, Choose Agent…, Quick Terminal). AppDelegate calls
/// `sync(menu:)` after every menu-shortcut sync (launch, config reload,
/// keyboard-layout change); the views observe it, so an open start screen
/// or sidebar follows a reload.
@MainActor final class LeoShortcutHints: ObservableObject {
    static let newTerminalAction = #selector(TerminalController.newTab(_:))
    static let chooseAgentAction = #selector(TerminalController.chooseLeoAgent(_:))
    static let quickTerminalAction = #selector(AppDelegate.toggleQuickTerminal(_:))

    /// Nil until the first sync, and whenever the item has no shortcut.
    @Published private(set) var newTerminal: String?
    @Published private(set) var chooseAgent: String?
    /// View ▸ Quick Terminal's: ships unbound (its keybind is global).
    @Published private(set) var quickTerminal: String?

    func sync(menu: NSMenu?) {
        let newTerminal = Self.hint(for: Self.newTerminalAction, in: menu)
        let chooseAgent = Self.hint(for: Self.chooseAgentAction, in: menu)
        let quickTerminal = Self.hint(for: Self.quickTerminalAction, in: menu)
        // Publish only real changes: every reload re-syncs.
        if newTerminal != self.newTerminal { self.newTerminal = newTerminal }
        if chooseAgent != self.chooseAgent { self.chooseAgent = chooseAgent }
        if quickTerminal != self.quickTerminal { self.quickTerminal = quickTerminal }
    }

    private static func hint(for action: Selector, in menu: NSMenu?) -> String? {
        LeoMenuShortcutHint.text(for: LeoMenuShortcutHint.menuItem(action: action, in: menu))
    }
}
