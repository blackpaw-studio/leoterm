import AppKit
import Carbon.HIToolbox

/// B-059: the Window menu's row items and their shortcuts.
///
/// Select Row ▸ Row 1–8 and Last Row follow Ghostty's `goto_tab:N` and
/// `last_tab` bindings (⌘1–⌘9 by default), so rebinding or unbinding them in
/// the Ghostty config moves or clears the menu's.
///
/// Select Next/Previous Row keep ⌃⇥ / ⌃⇧⇥ and are never synced to `next_tab`
/// / `previous_tab`: Ghostty's reverse lookup returns the last binding put,
/// which is ⇧⌘] / ⇧⌘[, the editor tabs' keys (D-460). Ghostty's default
/// ⌃Tab bindings are handed to these items instead, by physical key.
enum LeoRowMenuShortcuts {
    /// The Last Row item's tag; Row N has tag N.
    static let lastRowTag = 9

    @MainActor static func sync(
        _ config: Ghostty.Config, selectRow: NSMenuItem?, next: NSMenuItem?, previous: NSMenuItem?,
        manager: Ghostty.MenuShortcutManager
    ) {
        for item in selectRow?.submenu?.items ?? [] {
            let action = item.tag == lastRowTag ? "last_tab" : "goto_tab:\(item.tag)"
            manager.syncMenuShortcut(config, action: action, menuItem: item)
        }
        for item in [next, previous].compactMap({ $0 }) {
            manager.registerFixedShortcut(item, physicalKeyCode: UInt16(kVK_Tab))
        }
    }
}
