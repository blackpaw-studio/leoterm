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

    /// Every main-menu item (submenus included) on plain ⌘`key`.
    private func commandItems(_ key: String) -> [NSMenuItem] {
        func walk(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { [$0] + walk($0.submenu) }
        }
        return walk(NSApp.mainMenu).filter {
            $0.keyEquivalent == key && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
        }
    }

    /// B-066 (D-125): ⌘T is New Terminal and nothing else -- not the agent
    /// palette, not the quick terminal.
    @Test func commandTIsNewTerminalAlone() throws {
        let items = commandItems("t")

        #expect(items.map(\.title) == ["New Terminal"])
        #expect(items.first?.action == #selector(TerminalController.newTab(_:)))
        let quick = menuItems(#selector(AppDelegate.toggleQuickTerminal(_:)))
        #expect(!quick.isEmpty, "the quick terminal keeps its menu item")
        #expect(quick.allSatisfy { $0.keyEquivalent != "t" || $0.keyEquivalentModifierMask != .command })
        let intruders = try Self.commandTIntruders(LeoMenuXib.shortcuts())
        #expect(
            intruders.map(\.title) == [],
            "no xib item but New Terminal binds ⌘T or a bare T (New Terminal's own ⌘T comes from the config's new_tab)"
        )
    }

    // MARK: The xib ⌘T guard (B-076)

    /// Shortcuts only New Terminal may have in the xib: ⌘T, and a bare T,
    /// which is what an empty `<modifierMask/>` on a "t" key really binds.
    private static let commandTLookalikes: Set<String> = ["⌘t", "t"]

    private static func commandTIntruders(_ items: [LeoMenuXib.MenuShortcut]) -> [LeoMenuXib.MenuShortcut] {
        LeoMenuXib.claims(on: commandTLookalikes, byAnyoneBut: "newTab:", in: items)
    }

    /// Parses menu items as they'd sit in MainMenu.xib.
    private static func fixture(_ menuItems: String) throws -> [LeoMenuXib.MenuShortcut] {
        try LeoMenuXib.shortcuts(in: XMLDocument(xmlString: "<menu><items>\(menuItems)</items></menu>"))
    }

    private static let newTerminalOnCommandT = """
        <menuItem title="New Tab" keyEquivalent="t" id="n1">
            <connections><action selector="newTab:" target="-1" id="a1"/></connections>
        </menuItem>
        """

    /// Masks decode as a loaded nib reports them (ibtool + NSNib, B-076).
    @Test func xibModifierMasksDecodeLikeALoadedNib() throws {
        let items = try Self.fixture("""
            <menuItem title="None" keyEquivalent="t" id="i1"/>
            <menuItem title="Empty" keyEquivalent="t" id="i2"><modifierMask key="keyEquivalentModifierMask"/></menuItem>
            <menuItem title="Command" keyEquivalent="t" id="i3"><modifierMask key="keyEquivalentModifierMask" command="YES"/></menuItem>
            <menuItem title="Upper" keyEquivalent="T" id="i4"/>
            <menuItem title="Option" keyEquivalent="t" id="i5"><modifierMask key="keyEquivalentModifierMask" option="YES"/></menuItem>
            """)

        #expect(items.map(\.shortcut) == ["⌘t", "t", "⌘t", "⇧⌘t", "⌥t"])
    }

    @Test func theXibGuardFlagsAnotherItemOnCommandT() throws {
        let items = try Self.fixture(Self.newTerminalOnCommandT + """
            <menuItem title="Quick Terminal" keyEquivalent="t" id="q1">
                <connections><action selector="toggleQuickTerminal:" target="-1" id="a2"/></connections>
            </menuItem>
            """)

        #expect(Self.commandTIntruders(items).map(\.title) == ["Quick Terminal"])
    }

    @Test func theXibGuardFlagsABareTFromAnEmptyModifierMask() throws {
        let items = try Self.fixture(Self.newTerminalOnCommandT + """
            <menuItem title="Quick Terminal" keyEquivalent="t" id="q1">
                <modifierMask key="keyEquivalentModifierMask"/>
                <connections><action selector="toggleQuickTerminal:" target="-1" id="a2"/></connections>
            </menuItem>
            """)

        #expect(Self.commandTIntruders(items).map(\.title) == ["Quick Terminal"])
    }

    @Test func theXibGuardLeavesOtherTChordsAlone() throws {
        let items = try Self.fixture(Self.newTerminalOnCommandT + """
            <menuItem title="Shifted" keyEquivalent="T" id="s1">
                <connections><action selector="toggleQuickTerminal:" target="-1" id="a2"/></connections>
            </menuItem>
            <menuItem title="Optioned" keyEquivalent="t" id="o1">
                <modifierMask key="keyEquivalentModifierMask" option="YES" command="YES"/>
                <connections><action selector="toggleQuickTerminal:" target="-1" id="a3"/></connections>
            </menuItem>
            """)

        #expect(Self.commandTIntruders(items).isEmpty)
    }

    /// B-066: the start screen's Choose Agent… tooltip names the palette's
    /// real shortcut (⌘O), not ⌘T, which makes a terminal.
    @Test func thePlaceholderHintNamesChooseAgentsMenuShortcut() throws {
        let item = try #require(menuItems(#selector(TerminalController.chooseLeoAgent(_:))).first)
        let shortcut = "⌘" + item.keyEquivalent.uppercased()

        let help = LeoPlaceholderChooseAgent(host: .local, connectivity: .connected).help

        #expect(help != "⌘T", "⌘T is New Terminal")
        #expect(help == shortcut)
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
