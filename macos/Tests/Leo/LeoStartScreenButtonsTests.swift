import AppKit
import Testing

@testable import Ghostty

/// B-069, B-113: the start screen's New Terminal and Quick Terminal buttons
/// are the sidebar footer's buttons in bordered form: the same menu items,
/// named as the menu names them. Runs against the app the tests are hosted
/// in, so the main menu is the real one. B-080: items are found by their
/// action, not their key, so a rebound shortcut still finds them.
@MainActor @Suite(.serialized) struct LeoStartScreenButtonsTests {
    private func menuItem(for button: LeoSidebarButton) -> NSMenuItem? {
        LeoMenuShortcutHint.menuItem(action: button.action, in: NSApp.mainMenu)
    }

    /// The start screen draws a button per entry, titled and wired from
    /// the entry alone: it takes no titles or per-button closures, so its
    /// names can't drift from the menu's.
    @Test func theStartScreenNamesTheQuickTerminalAsTheMenuDoes() throws {
        let item = try #require(menuItem(for: .quickTerminal), "View ▸ Quick Terminal is in the main menu")

        #expect(LeoPlaceholderView.menuButtons.contains(.quickTerminal), "the start screen offers the quick terminal")
        #expect(LeoSidebarButton.quickTerminal.title == item.title, "named as the menu names it")
        #expect(item.title == "Quick Terminal")
    }

    @Test func theStartScreensButtonsAreTheSidebarFootersInOrder() throws {
        #expect(LeoPlaceholderView.menuButtons == [.newTerminal, .quickTerminal])
        for button in LeoPlaceholderView.menuButtons {
            let item = try #require(menuItem(for: button), "\(button) is in the main menu")
            #expect(button.title == item.title)
            #expect(button.action == item.action)
        }
    }

    /// B-104: New Terminal ships bound (⌘T, D-262), so a nil hint is a
    /// failure here, not a vacuous match of two nils.
    @Test func theNewTerminalHintNamesTheMenuItemsLiveShortcut() throws {
        let item = try #require(LeoMenuShortcutHint.menuItem(action: LeoShortcutHints.newTerminalAction, in: NSApp.mainMenu))
        let hints = try #require((NSApp.delegate as? AppDelegate)?.leoRuntime.shortcutHints)
        let shortcut = try #require(LeoMenuShortcutHint.text(for: item), "New Terminal carries a shortcut")

        #expect(hints.newTerminal == shortcut)
        #expect(LeoSidebarButton.newTerminal.hint(in: hints) == shortcut)
    }
}
