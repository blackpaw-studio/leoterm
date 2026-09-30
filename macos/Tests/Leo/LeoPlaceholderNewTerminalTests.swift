import AppKit
import Testing

@testable import Ghostty

/// B-069: the start screen's New Terminal button is File ▸ New Terminal
/// (⌘T) itself -- the menu item's own action, sent the way AppKit sends it,
/// and a tooltip naming the menu item's own shortcut. Runs against the app
/// the tests are hosted in, so the main menu is the real one.
@MainActor @Suite(.serialized) struct LeoPlaceholderNewTerminalTests {
    /// Every main-menu item (submenus included) on plain ⌘`key`.
    private func commandItems(_ key: String) -> [NSMenuItem] {
        func walk(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { [$0] + walk($0.submenu) }
        }
        return walk(NSApp.mainMenu).filter {
            $0.keyEquivalent == key && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
        }
    }

    /// Stands in for the window's controller: answers ⌘T's selector.
    private final class Recorder: NSObject {
        private(set) var senders: [Any?] = []
        @objc func newTab(_ sender: Any?) { senders.append(sender) }
    }

    @Test func theButtonIsTheCommandTMenuItem() throws {
        let item = try #require(commandItems("t").first, "⌘T is in the main menu")

        #expect(LeoPlaceholderNewTerminal.action == item.action)
        #expect(LeoPlaceholderNewTerminal.title == item.title)
    }

    @Test func theButtonsHintNamesTheCommandTMenuItemsShortcut() throws {
        let item = try #require(commandItems("t").first)

        #expect(LeoPlaceholderNewTerminal.help == "⌘" + item.keyEquivalent.uppercased())
    }

    @Test func pressingItSendsTheMenuActionToTheWindowsController() {
        let recorder = Recorder()

        let isHandled = LeoPlaceholderNewTerminal.send(to: recorder)

        #expect(isHandled)
        #expect(recorder.senders.count == 1, "exactly one New Terminal per press")
    }
}
