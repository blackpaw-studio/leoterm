import AppKit
import Testing

@testable import Ghostty

/// B-318: Edit ▸ Copy keeps ⌘C although Ghostty's default ⌘C is a
/// `performable` binding, which its reverse lookup (the menu sync's source)
/// leaves out.
@MainActor
struct LeoStandardEditShortcutsTests {
    private func syncedCopyItem(config text: String) throws -> NSMenuItem {
        let config = try TemporaryConfig(text)
        let item = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        let manager = Ghostty.MenuShortcutManager()
        manager.reset()
        manager.syncMenuShortcut(config, action: "copy_to_clipboard", menuItem: item)
        return item
    }

    @Test func copyShowsCommandCWithTheDefaultConfig() throws {
        let item = try syncedCopyItem(config: "")

        #expect(item.keyEquivalent == "c")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @Test func anUnboundCommandCLeavesCopyWithoutAShortcut() throws {
        let item = try syncedCopyItem(config: "keybind = super+c=unbind")

        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)
    }

    @Test func aConfiguredCopyShortcutStillWins() throws {
        let item = try syncedCopyItem(config: "keybind = super+shift+y=copy_to_clipboard")

        #expect(item.keyEquivalent == "y")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
    }
}
