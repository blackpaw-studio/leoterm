import AppKit
import Testing

@testable import Ghostty

/// B-055 (D-098, D-104): no window ever gets a tab bar, and the menu items
/// that only made sense with tabs are remapped or hidden. Runs against the
/// app the tests are hosted in, so the app delegate's launch setup has
/// already happened; the window checks bail out (rather than fail) without
/// the app's real `Ghostty.App`.
@MainActor @Suite(.serialized) struct LeoNoTabBarTests {
    private static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// Every main-menu item (submenus included) whose action is `selector`.
    private func menuItems(_ selector: Selector) -> [NSMenuItem] {
        func walk(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { [$0] + walk($0.submenu) }
        }
        return walk(NSApp.mainMenu).filter { $0.action == selector }
    }

    // MARK: Tabbing

    @Test func theAppNeverGroupsWindowsIntoTabs() {
        #expect(!NSWindow.allowsAutomaticWindowTabbing, "no Show Tab Bar / Merge All Windows, no system 'prefer tabs'")
    }

    @Test func aTerminalWindowDisallowsTabbingAndKeepsDisallowingIt() async throws {
        guard let ghostty = Self.ghostty else { return }
        let controller = TerminalController(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
        defer { controller.window?.close() }
        let window = try #require(controller.window)

        #expect(window.tabbingMode == .disallowed)
        // Upstream flipped `.preferred` to `.automatic` a turn after
        // awakeFromNib; nothing may turn tabbing back on.
        await nextMainTurn()
        #expect(window.tabbingMode == .disallowed)
        #expect(window.isVisible == false, "built, never shown")
    }

    @Test func theTabbingPolicyIsDisallowed() {
        #expect(LeoWindowTabbing.mode == .disallowed)
    }

    // MARK: Menus (D-104)

    /// B-057: ⌘T (Ghostty's `new_tab`) makes a terminal row.
    @Test func newTabIsNewTerminal() {
        let items = menuItems(#selector(TerminalController.newTab(_:)))

        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.title == "New Terminal" })
    }

    /// B-057: the palette keeps a menu item, now on ⌘O (⌘⇧P is Ghostty's
    /// command palette).
    @Test func chooseAgentIsCommandO() throws {
        let items = menuItems(#selector(TerminalController.chooseLeoAgent(_:)))

        #expect(items.map(\.title) == ["Choose Agent…"])
        #expect(items.first?.keyEquivalent == "o")
        #expect(items.first?.keyEquivalentModifierMask == .command)
        let xib = try LeoMenuXib.shortcuts().filter { $0.shortcut == "⌘o" }
        #expect(xib.map(\.action) == ["chooseLeoAgent:"], "nothing else in the menus uses ⌘O")
    }

    @Test func closeTabIsHidden() {
        let items = menuItems(#selector(TerminalController.closeTab(_:)))

        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.isHidden })
    }

    @Test func changeTabTitleNamesTheWindow() {
        let items = menuItems(#selector(BaseTerminalController.changeTabTitle(_:)))

        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.title == "Change Window Title…" })
    }

    @Test func theDockMenuOffersNewTerminalAndChooseAgentNotNewTab() {
        let items = (NSApp.delegate as? AppDelegate)?.applicationDockMenu(NSApp)?.items ?? []

        #expect(!items.map(\.title).contains("New Tab"))
        #expect(items.first { $0.title == "New Terminal" }?.action == #selector(AppDelegate.newTab(_:)))
        #expect(items.first { $0.title == "Choose Agent…" }?.action == #selector(AppDelegate.chooseLeoAgent(_:)))
    }
}
