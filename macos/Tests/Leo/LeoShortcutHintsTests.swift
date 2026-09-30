import AppKit
import Combine
import Testing

@testable import Ghostty

/// B-080: the start screen's shortcut hints are read off the live menu
/// items, which AppDelegate syncs from the Ghostty config's keybinds, so a
/// rebind (or a config reload) moves the hint with it. No shortcut means
/// no hint rather than a wrong one.
@MainActor @Suite(.serialized) struct LeoShortcutHintsTests {
    private static let newTab = #selector(TerminalController.newTab(_:))
    private static let chooseAgent = #selector(TerminalController.chooseLeoAgent(_:))

    private func item(_ key: String, _ modifiers: NSEvent.ModifierFlags, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "Item", action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// A File menu holding New Terminal and Choose Agent…, as in MainMenu.xib.
    private func menu(newTerminal: NSMenuItem, chooseAgent: NSMenuItem) -> NSMenu {
        let file = NSMenu(title: "File")
        file.addItem(newTerminal)
        file.addItem(chooseAgent)
        let main = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)
        return main
    }

    // MARK: Spelling a menu item's shortcut

    @Test func theHintSpellsTheMenuItemsShortcut() {
        #expect(LeoMenuShortcutHint.text(for: item("t", .command)) == "⌘T")
        #expect(LeoMenuShortcutHint.text(for: item("n", [.shift, .command])) == "⇧⌘N")
        #expect(LeoMenuShortcutHint.text(for: item("T", .command)) == "⇧⌘T", "an upper-case key equivalent implies ⇧")
        #expect(LeoMenuShortcutHint.text(for: item("k", [.command, .option, .control])) == "⌃⌥⌘K")
    }

    @Test func noShortcutMeansNoHint() {
        #expect(LeoMenuShortcutHint.text(for: nil) == nil)
        #expect(LeoMenuShortcutHint.text(for: item("", [])) == nil)
        #expect(LeoMenuShortcutHint.text(for: item("", .command)) == nil)
    }

    /// A key the hint can't spell (F1 is a private-use character) is left
    /// out rather than shown as a stray glyph.
    @Test func anUnspellableKeyMeansNoHint() {
        let f1 = String(Character(UnicodeScalar(NSF1FunctionKey)!))
        #expect(LeoMenuShortcutHint.text(for: item(f1, .command)) == nil)
    }

    /// Finds the item by its action, not its key, and prefers the one that
    /// carries a shortcut.
    @Test func theItemIsFoundByItsAction() {
        let bare = item("", [], action: Self.newTab)
        let bound = item("n", .command, action: Self.newTab)
        let file = NSMenu(title: "File")
        [bare, bound].forEach(file.addItem)
        let main = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)

        #expect(LeoMenuShortcutHint.menuItem(action: Self.newTab, in: main) === bound)
        #expect(LeoMenuShortcutHint.menuItem(action: Self.chooseAgent, in: main) == nil)
    }

    // MARK: Following the config

    /// The chain AppDelegate runs on launch and on every reload: the config's
    /// `new_tab` keybind → the synced menu item → the start-screen hint.
    @Test func theNewTerminalHintFollowsARebind() throws {
        let config = try TemporaryConfig("keybind = super+shift+n=new_tab")
        let newTerminal = item("", [], action: Self.newTab)
        let main = menu(newTerminal: newTerminal, chooseAgent: item("o", .command, action: Self.chooseAgent))
        let manager = Ghostty.MenuShortcutManager()
        let hints = LeoShortcutHints()
        func reload(_ text: String) throws {
            try config.reload(text)
            manager.reset()
            manager.syncMenuShortcut(config, action: "new_tab", menuItem: newTerminal)
            hints.sync(menu: main)
        }

        try reload("keybind = super+shift+n=new_tab")
        #expect(hints.newTerminal == "⇧⌘N")

        try reload("")
        #expect(hints.newTerminal == "⌘T", "back to Ghostty's default new_tab")

        try reload("keybind = super+t=unbind")
        #expect(hints.newTerminal == nil, "unbound: the hint drops the shortcut")
    }

    /// Choose Agent…'s ⌘O lives in the xib, but the hint reads the menu item
    /// all the same, so anything that changes the item moves the hint.
    @Test func theChooseAgentHintFollowsItsMenuItem() {
        let chooseAgent = item("o", .command, action: Self.chooseAgent)
        let main = menu(newTerminal: item("t", .command, action: Self.newTab), chooseAgent: chooseAgent)
        let hints = LeoShortcutHints()

        hints.sync(menu: main)
        #expect(hints.chooseAgent == "⌘O")

        chooseAgent.keyEquivalent = "k"
        chooseAgent.keyEquivalentModifierMask = [.command, .option]
        hints.sync(menu: main)
        #expect(hints.chooseAgent == "⌥⌘K")

        chooseAgent.keyEquivalent = ""
        hints.sync(menu: main)
        #expect(hints.chooseAgent == nil)
    }

    /// A reload while the start screen shows: the view observes the hints,
    /// so a sync that changes one must publish.
    @Test func aSyncThatChangesAHintPublishes() {
        let newTerminal = item("t", .command, action: Self.newTab)
        let main = menu(newTerminal: newTerminal, chooseAgent: item("o", .command, action: Self.chooseAgent))
        let hints = LeoShortcutHints()
        hints.sync(menu: main)
        var changes = 0
        let subscription = hints.objectWillChange.sink { changes += 1 }

        newTerminal.keyEquivalent = "n"
        hints.sync(menu: main)

        #expect(changes >= 1)
        #expect(hints.newTerminal == "⌘N")
        subscription.cancel()
    }

    /// Nothing to show before the first sync: no guessed shortcut.
    @Test func hintsStartEmpty() {
        let hints = LeoShortcutHints()
        #expect(hints.newTerminal == nil)
        #expect(hints.chooseAgent == nil)
    }

    // MARK: The running app

    /// The app's hints are the real menu's: AppDelegate syncs them with the
    /// menu shortcuts.
    @Test func theAppsHintsMatchTheRealMenu() throws {
        let runtime = try #require((NSApp.delegate as? AppDelegate)?.leoRuntime)
        let newTerminal = try #require(LeoMenuShortcutHint.menuItem(action: Self.newTab, in: NSApp.mainMenu))
        let chooseAgent = try #require(LeoMenuShortcutHint.menuItem(action: Self.chooseAgent, in: NSApp.mainMenu))

        #expect(runtime.shortcutHints.newTerminal == LeoMenuShortcutHint.text(for: newTerminal))
        #expect(runtime.shortcutHints.chooseAgent == LeoMenuShortcutHint.text(for: chooseAgent))
    }
}
