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
        let xib = try LeoMenuXib.shortcuts()
        #expect(xib.contains { $0.action == "chooseLeoAgent:" && $0.shortcut == "⌘o" })
        #expect(Self.commandOIntruders(xib).map(\.title) == [], "no xib item but Choose Agent… binds ⌘O, and none binds a bare O")
        #expect(
            Self.commandOIntruders(LeoMenuXib.shortcuts(in: NSApp.mainMenu)).map(\.title) == [],
            "no live menu item but Choose Agent… binds ⌘O, and none binds a bare O"
        )
    }

    /// B-066 (D-125): ⌘T is New Terminal and nothing else -- not the agent
    /// palette, not the quick terminal.
    @Test func commandTIsNewTerminalAlone() throws {
        let live = LeoMenuXib.shortcuts(in: NSApp.mainMenu)

        #expect(live.filter { $0.shortcut == "⌘t" }.map(\.title) == ["New Terminal"])
        #expect(live.first { $0.shortcut == "⌘t" }?.action == "newTab:")
        #expect(!menuItems(#selector(AppDelegate.toggleQuickTerminal(_:))).isEmpty, "the quick terminal keeps its menu item")
        #expect(
            Self.commandTIntruders(live).map(\.title) == [],
            "no live menu item but New Terminal binds ⌘T, and none binds a bare T"
        )
        let intruders = try Self.commandTIntruders(LeoMenuXib.shortcuts())
        #expect(
            intruders.map(\.title) == [],
            "no xib item but New Terminal binds ⌘T, and none binds a bare T (New Terminal's own ⌘T comes from the config's new_tab)"
        )
    }

    // MARK: The xib ⌘T guard (B-076)

    /// Only New Terminal may hold ⌘T; nothing, New Terminal included, may
    /// hold a bare T, which is what an empty `<modifierMask/>` really binds.
    private static func commandTIntruders(_ items: [LeoMenuXib.MenuShortcut]) -> [LeoMenuXib.MenuShortcut] {
        LeoMenuXib.intruders(onCommand: "t", ownedBy: "newTab:", in: items)
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

    /// B-102: New Terminal may hold only ⌘T, never a bare T.
    @Test func theXibGuardFlagsABareTOnNewTerminal() throws {
        let items = try Self.fixture("""
            <menuItem title="New Tab" keyEquivalent="t" id="n1">
                <modifierMask key="keyEquivalentModifierMask"/>
                <connections><action selector="newTab:" target="-1" id="a1"/></connections>
            </menuItem>
            """)

        #expect(Self.commandTIntruders(items).map(\.title) == ["New Tab"])
    }

    // MARK: The ⌘O guard (B-102)

    /// Only Choose Agent… may hold ⌘O; nothing may hold a bare O.
    private static func commandOIntruders(_ items: [LeoMenuXib.MenuShortcut]) -> [LeoMenuXib.MenuShortcut] {
        LeoMenuXib.intruders(onCommand: "o", ownedBy: "chooseLeoAgent:", in: items)
    }

    private static let chooseAgentOnCommandO = """
        <menuItem title="Choose Agent…" keyEquivalent="o" id="c1">
            <connections><action selector="chooseLeoAgent:" target="-1" id="a1"/></connections>
        </menuItem>
        """

    @Test func theOGuardFlagsAnotherItemOnCommandOOrABareO() throws {
        let items = try Self.fixture(Self.chooseAgentOnCommandO + """
            <menuItem title="Open" keyEquivalent="o" id="o1">
                <connections><action selector="openDocument:" target="-1" id="a2"/></connections>
            </menuItem>
            <menuItem title="Bare" keyEquivalent="o" id="o2">
                <modifierMask key="keyEquivalentModifierMask"/>
                <connections><action selector="openFileInLeoEditor:" target="-1" id="a3"/></connections>
            </menuItem>
            """)

        #expect(Self.commandOIntruders(items).map(\.title) == ["Open", "Bare"])
    }

    @Test func theOGuardFlagsABareOOnChooseAgent() throws {
        let items = try Self.fixture("""
            <menuItem title="Choose Agent…" keyEquivalent="o" id="c1">
                <modifierMask key="keyEquivalentModifierMask"/>
                <connections><action selector="chooseLeoAgent:" target="-1" id="a1"/></connections>
            </menuItem>
            """)

        #expect(Self.commandOIntruders(items).map(\.title) == ["Choose Agent…"])
    }

    @Test func theOGuardLeavesChooseAgentAndOtherOChordsAlone() throws {
        let items = try Self.fixture(Self.chooseAgentOnCommandO + """
            <menuItem title="Open File in Editor…" keyEquivalent="O" id="s1">
                <modifierMask key="keyEquivalentModifierMask" shift="YES" command="YES"/>
                <connections><action selector="openFileInLeoEditor:" target="-1" id="a2"/></connections>
            </menuItem>
            <menuItem title="Open Surfaced File" keyEquivalent="o" id="s2">
                <modifierMask key="keyEquivalentModifierMask" option="YES" command="YES"/>
                <connections><action selector="openLeoSurfacedFile:" target="-1" id="a3"/></connections>
            </menuItem>
            """)

        #expect(Self.commandOIntruders(items).isEmpty)
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

    // MARK: The live-menu guard (B-102)

    private static func liveItem(_ title: String, _ action: String, _ key: String, _ mask: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        return item
    }

    /// A fake main menu: `items` sit in a File submenu.
    private static func liveMenu(_ items: [NSMenuItem]) -> NSMenu {
        let file = NSMenu(title: "File")
        items.forEach(file.addItem)
        let main = NSMenu(title: "Main")
        let top = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        top.submenu = file
        main.addItem(top)
        return main
    }

    @Test func liveShortcutsDecodeLikeTheXib() {
        let menu = Self.liveMenu([
            Self.liveItem("Command", "a:", "t", .command),
            Self.liveItem("Bare", "b:", "t", []),
            Self.liveItem("Upper", "c:", "T", .command),
            Self.liveItem("Option", "d:", "t", .option),
            Self.liveItem("None", "e:", "", .command),
        ])

        let shortcuts = LeoMenuXib.shortcuts(in: menu)

        #expect(shortcuts.map(\.shortcut) == ["⌘t", "t", "⇧⌘t", "⌥t"])
        #expect(shortcuts.map(\.action) == ["a:", "b:", "c:", "d:"])
    }

    @Test func theLiveGuardFlagsAnyItemOnCommandTOrABareT() {
        let menu = Self.liveMenu([
            Self.liveItem("New Terminal", "newTab:", "t", .command),
            Self.liveItem("Close Window", "performClose:", "t", .command),
            Self.liveItem("Bare", "toggleQuickTerminal:", "t", []),
        ])

        #expect(Self.commandTIntruders(LeoMenuXib.shortcuts(in: menu)).map(\.title) == ["Close Window", "Bare"])
    }

    @Test func theLiveGuardFlagsABareTOnNewTerminal() {
        let menu = Self.liveMenu([Self.liveItem("New Terminal", "newTab:", "t", [])])

        #expect(Self.commandTIntruders(LeoMenuXib.shortcuts(in: menu)).map(\.title) == ["New Terminal"])
    }

    /// B-066: the start screen's Choose Agent… tooltip names the palette's
    /// real shortcut (⌘O), not ⌘T, which makes a terminal. B-080: it is
    /// read off the live menu item.
    @Test func thePlaceholderHintNamesChooseAgentsMenuShortcut() throws {
        let item = try #require(menuItems(#selector(TerminalController.chooseLeoAgent(_:))).first)
        let hints = try #require((NSApp.delegate as? AppDelegate)?.leoRuntime.shortcutHints)

        let help = LeoPlaceholderChooseAgent(host: .local, connectivity: .connected, shortcut: hints.chooseAgent).help

        #expect(help == "⌘O")
        #expect(help == LeoMenuShortcutHint.text(for: item))
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
