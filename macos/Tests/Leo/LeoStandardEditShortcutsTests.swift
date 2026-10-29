import AppKit
import Testing

@testable import Ghostty

/// B-318, B-325: Edit ▸ Copy and Paste keep ⌘C and ⌘V although Ghostty's
/// default bindings for them are `performable`, which its reverse lookup (the
/// menu sync's source) leaves out.
@MainActor
struct LeoStandardEditShortcutsTests {
    private func syncedCopyItem(config text: String) throws -> NSMenuItem {
        try syncedItem(config: text, title: "Copy", action: "copy_to_clipboard", selector: #selector(NSText.copy(_:)))
    }

    private func syncedPasteItem(config text: String) throws -> NSMenuItem {
        try syncedItem(config: text, title: "Paste", action: "paste_from_clipboard", selector: #selector(NSText.paste(_:)))
    }

    private func syncedItem(config text: String, title: String, action: String, selector: Selector) throws -> NSMenuItem {
        let config = try TemporaryConfig(text)
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        let manager = Ghostty.MenuShortcutManager()
        manager.reset()
        manager.syncMenuShortcut(config, action: action, menuItem: item)
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

    @Test func pasteShowsCommandVWithTheDefaultConfig() throws {
        let item = try syncedPasteItem(config: "")

        #expect(item.keyEquivalent == "v")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @Test func anUnboundCommandVLeavesPasteWithoutAShortcut() throws {
        let item = try syncedPasteItem(config: "keybind = super+v=unbind")

        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)
    }

    @Test func aConfiguredPasteShortcutStillWins() throws {
        let item = try syncedPasteItem(config: "keybind = super+shift+y=paste_from_clipboard")

        #expect(item.keyEquivalent == "y")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
    }
}
