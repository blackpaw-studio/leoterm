import AppKit
import Carbon.HIToolbox

/// B-397: App menu ▸ Settings… owns ⌘, and opens the Leo settings window.
///
/// Ghostty's default keybinds also put `open_config` on ⌘,, and the menu
/// sync would hand that shortcut to whichever item is synced to it. So
/// Open Ghostty Config is never synced to `open_config` (it has no
/// shortcut), and a ⌘, keybind in a terminal is dispatched to Settings…
/// by physical key, the way the Window menu takes ⌃Tab (B-059).
enum LeoSettingsMenuShortcut {
    @MainActor static func sync(settings: NSMenuItem?, manager: Ghostty.MenuShortcutManager) {
        guard let settings else { return }
        manager.registerFixedShortcut(settings, physicalKeyCode: UInt16(kVK_ANSI_Comma))
    }
}
