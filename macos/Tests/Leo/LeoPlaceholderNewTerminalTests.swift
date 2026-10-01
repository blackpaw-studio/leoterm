import AppKit
import Testing

@testable import Ghostty

/// B-069: the start screen's New Terminal button is File ▸ New Terminal
/// itself -- the menu item's own action, sent the way AppKit sends it,
/// and a tooltip naming the menu item's own shortcut. Runs against the app
/// the tests are hosted in, so the main menu is the real one. B-080: the
/// item is found by its action, not its key, so a rebound `new_tab` still
/// finds it and the hint is checked against whatever it is bound to.
@MainActor @Suite(.serialized) struct LeoPlaceholderNewTerminalTests {
    /// File ▸ New Terminal, by its action.
    private func newTerminalItem() -> NSMenuItem? {
        LeoMenuShortcutHint.menuItem(action: #selector(TerminalController.newTab(_:)), in: NSApp.mainMenu)
    }

    /// Stands in for the window's controller: answers New Terminal's selector.
    private final class Recorder: NSObject {
        private(set) var senders: [Any?] = []
        @objc func newTab(_ sender: Any?) { senders.append(sender) }
    }

    @Test func theButtonIsTheNewTerminalMenuItem() throws {
        let item = try #require(newTerminalItem(), "New Terminal is in the main menu")

        #expect(LeoPlaceholderNewTerminal.action == item.action)
        #expect(LeoPlaceholderNewTerminal.title == item.title)
    }

    /// B-104: New Terminal ships bound (⌘T, D-262), so a nil hint is a
    /// failure here, not a vacuous match of two nils.
    @Test func theButtonsHintNamesTheMenuItemsLiveShortcut() throws {
        let item = try #require(newTerminalItem())
        let hints = try #require((NSApp.delegate as? AppDelegate)?.leoRuntime.shortcutHints)
        let shortcut = try #require(LeoMenuShortcutHint.text(for: item), "New Terminal carries a shortcut")

        #expect(hints.newTerminal == shortcut)
    }

    @Test func pressingItSendsTheMenuActionToTheWindowsController() {
        let recorder = Recorder()

        let isHandled = LeoPlaceholderNewTerminal.send(to: recorder)

        #expect(isHandled)
        #expect(recorder.senders.count == 1, "exactly one New Terminal per press")
    }
}
