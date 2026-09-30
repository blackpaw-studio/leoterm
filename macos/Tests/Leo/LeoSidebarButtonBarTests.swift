import AppKit
import Testing

@testable import Ghostty

/// B-065: the sidebar's footer buttons are menu items, not copies. Each
/// sends its menu item's own action, names the item's live shortcut in its
/// tooltip, and is labelled with the item's title. Runs against the app the
/// tests are hosted in, so the main menu is the real one.
@MainActor @Suite(.serialized) struct LeoSidebarButtonBarTests {
    /// The main-menu item a button stands for, found by its action.
    private func menuItem(for button: LeoSidebarButton) -> NSMenuItem? {
        LeoMenuShortcutHint.menuItem(action: button.action, in: NSApp.mainMenu)
    }

    /// Stands in for the window's controller and the app delegate: answers
    /// both buttons' selectors and counts the presses.
    private final class Recorder: NSObject {
        private(set) var newTabs = 0
        private(set) var quickTerminalToggles = 0
        @objc func newTab(_ sender: Any?) { newTabs += 1 }
        @objc func toggleQuickTerminal(_ sender: Any?) { quickTerminalToggles += 1 }
    }

    @Test func newTerminalButtonIsTheNewTerminalMenuItem() throws {
        let item = try #require(menuItem(for: .newTerminal), "File ▸ New Terminal is in the main menu")

        #expect(LeoSidebarButton.newTerminal.action == #selector(TerminalController.newTab(_:)))
        #expect(LeoSidebarButton.newTerminal.title == item.title)
        #expect(LeoSidebarButton.newTerminal.action == LeoPlaceholderNewTerminal.action, "the same action as ⌘T and the start screen")
    }

    @Test func quickTerminalButtonIsTheQuickTerminalMenuItem() throws {
        let item = try #require(menuItem(for: .quickTerminal), "View ▸ Quick Terminal is in the main menu")

        #expect(LeoSidebarButton.quickTerminal.action == #selector(AppDelegate.toggleQuickTerminal(_:)))
        #expect(LeoSidebarButton.quickTerminal.title == item.title)
    }

    @Test func pressingNewTerminalSendsOneNewTabToTheWindowsController() {
        let recorder = Recorder()

        let isHandled = LeoSidebarButton.newTerminal.send(to: recorder)

        #expect(isHandled)
        #expect(recorder.newTabs == 1, "exactly one New Terminal per press")
        #expect(recorder.quickTerminalToggles == 0)
    }

    @Test func pressingQuickTerminalSendsToggleQuickTerminal() {
        let recorder = Recorder()

        let isHandled = LeoSidebarButton.quickTerminal.send(to: recorder)

        #expect(isHandled)
        #expect(recorder.quickTerminalToggles == 1, "exactly one toggle per press")
        #expect(recorder.newTabs == 0)
    }

    @Test func tooltipsNameTheLiveShortcut() throws {
        #expect(LeoSidebarButton.newTerminal.tooltip(hint: "⌘T") == "New Terminal ⌘T")
        #expect(LeoSidebarButton.newTerminal.tooltip(hint: "⇧⌘N") == "New Terminal ⇧⌘N", "follows a rebind")
        #expect(LeoSidebarButton.quickTerminal.tooltip(hint: nil) == "Quick Terminal", "unbound: the title alone")
        #expect(LeoSidebarButton.quickTerminal.tooltip(hint: "") == "Quick Terminal", "never a dangling space")

        let hints = try #require((NSApp.delegate as? AppDelegate)?.leoRuntime.shortcutHints)
        for button in LeoSidebarButton.allCases {
            let item = try #require(menuItem(for: button))
            #expect(button.hint(in: hints) == LeoMenuShortcutHint.text(for: item), "\(button) reads its menu item's shortcut")
        }
    }

    @Test func accessibilityLabelsAreTheMenuTitles() throws {
        for button in LeoSidebarButton.allCases {
            let item = try #require(menuItem(for: button))
            #expect(!button.accessibilityLabel.isEmpty)
            #expect(button.accessibilityLabel == item.title)
        }
    }

    @Test func buttonsHaveDistinctSymbols() {
        let symbols = LeoSidebarButton.allCases.map(\.systemImage)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
    }

    @Test func newTerminalComesFirst() {
        #expect(LeoSidebarButton.allCases == [.newTerminal, .quickTerminal])
    }
}
