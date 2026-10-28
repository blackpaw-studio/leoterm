import AppKit
import Carbon.HIToolbox
import GhosttyKit

/// B-318: the standard macOS shortcut for an Edit menu item whose Ghostty
/// default binding is `performable`. Ghostty's reverse lookup, which the
/// menu sync reads, leaves performable bindings out, so the sync would give
/// the item no key equivalent. A focused terminal surface still answers the
/// key itself (a key equivalent reaches the window's views before the
/// menu), but selected text anywhere else -- a chat bubble, a text field --
/// can only be copied through the menu.
///
/// Only Copy. Paste's ⌘V is performable too; Find's ⌘F is handled by
/// `LeoFindableTextView` instead, since Edit ▸ Find climbs to the terminal.
enum LeoStandardEditShortcut {
    private struct Shortcut {
        let key: Character
        let keyCode: Int
    }

    private static let shortcuts = ["copy_to_clipboard": Shortcut(key: "c", keyCode: kVK_ANSI_C)]

    /// Gives `item` the standard ⌘ shortcut for `action` while the config
    /// still binds that key; false when there is none to give (an `unbind`
    /// hands the key to the terminal program, so the menu must not take it).
    @MainActor static func apply(_ config: Ghostty.Config, action: String?, to item: NSMenuItem) -> Bool {
        guard let action, let shortcut = shortcuts[action], isBound(shortcut, in: config) else { return false }
        item.keyEquivalent = String(shortcut.key)
        item.keyEquivalentModifierMask = .command
        item.allowsAutomaticKeyEquivalentLocalization = true
        item.allowsAutomaticKeyEquivalentMirroring = true
        return true
    }

    private static func isBound(_ shortcut: Shortcut, in config: Ghostty.Config) -> Bool {
        guard let cfg = config.config, let scalar = shortcut.key.unicodeScalars.first else { return false }
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.mods = GHOSTTY_MODS_SUPER
        event.keycode = UInt32(shortcut.keyCode)
        event.unshifted_codepoint = scalar.value
        return String(shortcut.key).withCString { text in
            event.text = text
            return ghostty_config_key_is_binding(cfg, event)
        }
    }
}
