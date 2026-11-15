import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import Ghostty

/// B-059: Window ▸ Select Next/Previous Row (⌃⇥ / ⌃⇧⇥), Select Row ▸ Row
/// 1–8 and Last Row (⌘1–⌘9 from Ghostty's goto_tab bindings), and Jump to
/// Next Needing Attention (⌃⌥⌘J), moved here from Agents.
private final class Recorder: NSObject {
    var fired: [String] = []
    @objc func next(_ sender: Any?) { fired.append("next") }
    @objc func previous(_ sender: Any?) { fired.append("previous") }
}

@MainActor struct LeoRowMenuTests {
    private static let tab = "\t"

    /// The Select Row submenu as MainMenu.xib builds it: titles and tags,
    /// no shortcuts until the sync.
    private func selectRowItem() throws -> NSMenuItem {
        let document = try XMLDocument(contentsOf: LeoMenuXib.xibURL)
        let items = try document.nodes(forXPath: "//menuItem[@id='Leo-Window-SelectRow']/menu/items/menuItem").compactMap { $0 as? XMLElement }
        let submenu = NSMenu(title: "Select Row")
        submenu.autoenablesItems = false
        for element in items {
            let item = NSMenuItem(title: element.attribute(forName: "title")?.stringValue ?? "", action: nil, keyEquivalent: "")
            item.tag = Int(element.attribute(forName: "tag")?.stringValue ?? "") ?? 0
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: "Select Row", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func nextAndPrevious() throws -> (NSMenuItem, NSMenuItem) {
        let document = try XMLDocument(contentsOf: LeoMenuXib.xibURL)
        func item(_ id: String, _ key: String, _ flags: NSEvent.ModifierFlags) throws -> NSMenuItem {
            let xml = try #require(try document.nodes(forXPath: "//menuItem[@id='\(id)']").first as? XMLElement)
            let item = NSMenuItem(title: xml.attribute(forName: "title")?.stringValue ?? "", action: nil, keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            return item
        }
        return (try item("Leo-Window-NextRow", Self.tab, .control), try item("Leo-Window-PreviousRow", Self.tab, [.control, .shift]))
    }

    private struct Synced {
        let row: NSMenuItem
        let next: NSMenuItem
        let previous: NSMenuItem
        let manager: Ghostty.MenuShortcutManager
        let recorder = Recorder()

        /// The next/previous items in a Window menu, wired to `recorder`.
        func windowMenu() -> NSMenu {
            next.target = recorder
            next.action = #selector(Recorder.next(_:))
            previous.target = recorder
            previous.action = #selector(Recorder.previous(_:))
            let menu = NSMenu(title: "Window")
            menu.autoenablesItems = false
            menu.addItem(next)
            menu.addItem(previous)
            return menu
        }
    }

    private func sync(config text: String = "") throws -> Synced {
        let config = try TemporaryConfig(text)
        let (next, previous) = try nextAndPrevious()
        let synced = Synced(row: try selectRowItem(), next: next, previous: previous, manager: Ghostty.MenuShortcutManager())
        synced.manager.reset()
        LeoRowMenuShortcuts.sync(
            config, selectRow: synced.row, next: next, previous: previous, manager: synced.manager
        )
        return synced
    }

    @Test func windowMenuHasRowItemsWithShortcuts() throws {
        let document = try XMLDocument(contentsOf: LeoMenuXib.xibURL)
        let window = "//menuItem[@title='Window']/menu/items"
        let titles = try document.nodes(forXPath: "\(window)/menuItem/@title").compactMap(\.stringValue)
        #expect(titles.contains("Select Next Row") && titles.contains("Select Previous Row") && titles.contains("Select Row"))
        #expect(try LeoMenuXib.titles(forAction: "selectNextLeoRow:") == ["Select Next Row"])
        #expect(try LeoMenuXib.titles(forAction: "selectPreviousLeoRow:") == ["Select Previous Row"])
        #expect(try LeoMenuXib.titles(forAction: "selectLeoRowByNumber:") == (1 ... 8).map { "Row \($0)" })
        #expect(try LeoMenuXib.titles(forAction: "selectLastLeoRow:") == ["Last Row"])

        let items = try LeoMenuXib.shortcuts()
        #expect(items.first { $0.action == "selectNextLeoRow:" }?.shortcut == "⌃\(Self.tab)")
        #expect(items.first { $0.action == "selectPreviousLeoRow:" }?.shortcut == "⌃⇧\(Self.tab)")

        let synced = try sync().row.submenu?.items ?? []
        #expect(synced.map(\.title) == (1 ... 8).map { "Row \($0)" } + ["Last Row"])
        #expect(synced.map(\.keyEquivalent) == (1 ... 9).map(String.init), "⌘1–⌘8 from goto_tab, ⌘9 from last_tab")
        #expect(synced.allSatisfy { $0.keyEquivalentModifierMask == .command })
    }

    @Test func rowShortcutsFollowTheGhosttyConfig() throws {
        let rebound = try sync(config: "keybind = super+shift+u=goto_tab:2").row.submenu?.items ?? []
        #expect(rebound[1].keyEquivalent == "u" && rebound[1].keyEquivalentModifierMask == [.command, .shift])
        #expect(rebound[0].keyEquivalent == "1", "the others keep theirs")
    }

    @Test func jumpToNextNeedingAttentionIsInWindowMenu() throws {
        let document = try XMLDocument(contentsOf: LeoMenuXib.xibURL)
        let inWindow = try document.nodes(forXPath: "//menuItem[@title='Window']/menu/items/menuItem[@id='Leo-Agents-JumpAttention']")
        #expect(inWindow.count == 1)
        #expect(try document.nodes(forXPath: "//menuItem[@title='Agents']//menuItem[@id='Leo-Agents-JumpAttention']").isEmpty)
        let jump = try LeoMenuXib.shortcuts().filter { $0.action == "jumpToNextLeoAgentNeedingAttention:" }
        #expect(jump.map(\.shortcut) == ["⌃⌥⌘j"])
    }

    // MARK: ⌃Tab from the terminal

    private func keyDown(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: Self.tab, charactersIgnoringModifiers: Self.tab, isARepeat: false, keyCode: UInt16(kVK_Tab)
        ))
    }

    @Test func controlTabBindingResolvesToSelectNextRow_andControlShiftTabToPrevious() throws {
        let synced = try sync()
        let menu = synced.windowMenu()

        #expect(synced.manager.performGhosttyBindingMenuKeyEquivalent(with: try keyDown(.control)))
        #expect(synced.manager.performGhosttyBindingMenuKeyEquivalent(with: try keyDown([.control, .shift])))
        #expect(synced.recorder.fired == ["next", "previous"])
        #expect(menu.items.count == 2)
    }

    @Test func aResetDropsTheFixedShortcutsUntilTheyAreRegisteredAgain() throws {
        let synced = try sync()
        let menu = synced.windowMenu()
        synced.manager.reset()
        #expect(!synced.manager.performGhosttyBindingMenuKeyEquivalent(with: try keyDown(.control)))

        LeoRowMenuShortcuts.sync(
            try TemporaryConfig(""), selectRow: synced.row, next: synced.next, previous: synced.previous, manager: synced.manager
        )
        #expect(synced.manager.performGhosttyBindingMenuKeyEquivalent(with: try keyDown(.control)))
        #expect(synced.recorder.fired == ["next"])
        #expect(menu.items.count == 2)
    }

    // MARK: Shortcut ownership

    @Test func shiftCmdBracketStillShowsNextEditorTab() throws {
        let items = try LeoMenuXib.shortcuts()
        #expect(items.filter { $0.shortcut == "⇧⌘]" }.map(\.action) == ["showNextLeoEditorTab:"])
        #expect(items.filter { $0.shortcut == "⇧⌘[" }.map(\.action) == ["showPreviousLeoEditorTab:"])
        let synced = try sync()
        let menu = NSMenu()
        menu.addItem(synced.next)
        menu.addItem(synced.previous)
        #expect(LeoMenuXib.shortcuts(in: menu).map(\.shortcut) == ["⌃\(Self.tab)", "⌃⇧\(Self.tab)"],
                "the row items are never synced to next_tab, which would give them ⇧⌘]")
    }

    @Test func noTwoMainMenuItemsShareAShortcutAfterSync() throws {
        let menu = NSMenu()
        menu.addItem(try sync().row)
        let all = try LeoMenuXib.shortcuts() + LeoMenuXib.shortcuts(in: menu)
        let duplicates = Dictionary(grouping: all, by: \.shortcut).filter { $0.value.count > 1 }
        #expect(duplicates.isEmpty, "\(duplicates.keys.sorted())")
    }
}
