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
    private static let quickTerminal = #selector(AppDelegate.toggleQuickTerminal(_:))
    private static let reconnect = #selector(TerminalController.reconnectLeo(_:))

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

    /// B-104: AppKit carries F1–F35 as private-use characters; the hint
    /// spells them the way the menu bar does ("⌘F1"), not as a stray glyph.
    @Test func aFunctionKeyShortcutIsSpelled() {
        #expect(LeoMenuShortcutHint.text(for: item(functionKey(NSF1FunctionKey), .command)) == "⌘F1")
        #expect(LeoMenuShortcutHint.text(for: item(functionKey(NSF12FunctionKey), [.shift, .command])) == "⇧⌘F12")
        #expect(LeoMenuShortcutHint.text(for: item(functionKey(NSF35FunctionKey), [.control, .option])) == "⌃⌥F35")
    }

    /// A key the hint can't spell (Insert has no Mac key cap; a bare control
    /// character) is left out rather than shown as a stray glyph.
    @Test func anUnspellableKeyMeansNoHint() {
        #expect(LeoMenuShortcutHint.text(for: item(functionKey(NSInsertFunctionKey), .command)) == nil)
        #expect(LeoMenuShortcutHint.text(for: item("\u{1}", .command)) == nil)
    }

    private func functionKey(_ key: Int) -> String {
        UnicodeScalar(key).map { String(Character($0)) } ?? ""
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

    /// B-065: the sidebar's Quick Terminal button reads View ▸ Quick
    /// Terminal's shortcut the same way. It ships unbound (the keybind is
    /// global), so no hint until the config binds it.
    @Test func theQuickTerminalHintFollowsItsMenuItem() {
        let quickTerminal = item("", [], action: Self.quickTerminal)
        let main = menu(newTerminal: item("t", .command, action: Self.newTab), chooseAgent: quickTerminal)
        let hints = LeoShortcutHints()

        hints.sync(menu: main)
        #expect(hints.quickTerminal == nil, "unbound: no hint")

        quickTerminal.keyEquivalent = "`"
        quickTerminal.keyEquivalentModifierMask = [.command, .option]
        hints.sync(menu: main)
        #expect(hints.quickTerminal == "⌥⌘`")
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

    /// B-104: AppDelegate re-syncs on every config reload and layout change;
    /// a sync that changes nothing must not publish, or every open start
    /// screen and sidebar redraws for nothing.
    @Test func aSyncWithUnchangedShortcutsDoesNotPublish() {
        let quickTerminal = NSMenuItem(title: "Quick Terminal", action: Self.quickTerminal, keyEquivalent: "")
        let main = menu(newTerminal: item("t", .command, action: Self.newTab), chooseAgent: item("o", .command, action: Self.chooseAgent))
        main.items.first?.submenu?.addItem(quickTerminal)
        main.items.first?.submenu?.addItem(item("R", .command, action: Self.reconnect))
        let hints = LeoShortcutHints()
        hints.sync(menu: main)
        var changes = 0
        let subscription = hints.objectWillChange.sink { changes += 1 }

        hints.sync(menu: main)

        #expect(changes == 0)
        #expect(hints.newTerminal == "⌘T")
        #expect(hints.reconnect == "⇧⌘R")
        subscription.cancel()
    }

    /// B-104: the disconnected Choose Agent… tooltip names Agents ▸
    /// Reconnect's shortcut off its menu item too (⇧⌘R in the xib).
    @Test func theReconnectHintFollowsItsMenuItem() {
        let reconnect = item("R", .command, action: Self.reconnect)
        let main = menu(newTerminal: item("t", .command, action: Self.newTab), chooseAgent: reconnect)
        let hints = LeoShortcutHints()

        hints.sync(menu: main)
        #expect(hints.reconnect == "⇧⌘R")

        reconnect.keyEquivalent = ""
        hints.sync(menu: main)
        #expect(hints.reconnect == nil)
    }

    /// Nothing to show before the first sync: no guessed shortcut.
    @Test func hintsStartEmpty() {
        let hints = LeoShortcutHints()
        #expect(hints.newTerminal == nil)
        #expect(hints.chooseAgent == nil)
        #expect(hints.quickTerminal == nil)
        #expect(hints.reconnect == nil)
    }

    // MARK: The running app

    /// The app's hints are the real menu's: AppDelegate syncs them with the
    /// menu shortcuts. B-104: Choose Agent… (⌘O) and Reconnect (⇧⌘R) carry
    /// their shortcuts in the xib, so a nil on both sides is a failure, not
    /// a match. Quick Terminal ships unbound, so nil is a real answer there.
    @Test func theAppsHintsMatchTheRealMenu() throws {
        let runtime = try #require((NSApp.delegate as? AppDelegate)?.leoRuntime)
        let hints = runtime.shortcutHints
        let newTerminal = try #require(LeoMenuShortcutHint.menuItem(action: Self.newTab, in: NSApp.mainMenu))
        let chooseAgent = try #require(LeoMenuShortcutHint.menuItem(action: Self.chooseAgent, in: NSApp.mainMenu))
        let reconnect = try #require(LeoMenuShortcutHint.menuItem(action: Self.reconnect, in: NSApp.mainMenu))

        #expect(hints.newTerminal == LeoMenuShortcutHint.text(for: newTerminal))
        let chooseAgentHint = try #require(hints.chooseAgent, "Choose Agent… carries ⌘O")
        let reconnectHint = try #require(hints.reconnect, "Reconnect carries ⇧⌘R")
        #expect(chooseAgentHint == LeoMenuShortcutHint.text(for: chooseAgent))
        #expect(reconnectHint == LeoMenuShortcutHint.text(for: reconnect))
        let quickTerminal = try #require(LeoMenuShortcutHint.menuItem(action: Self.quickTerminal, in: NSApp.mainMenu))
        #expect(hints.quickTerminal == LeoMenuShortcutHint.text(for: quickTerminal))
    }
}
