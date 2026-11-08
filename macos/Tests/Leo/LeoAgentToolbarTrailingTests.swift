import AppKit
import Combine
import Testing

@testable import Ghostty

/// The toolbar's trailing items for an agent window: the Terminal | Chat
/// switch, Interrupt, then "⋯". They are always there (never hidden), the
/// switch reflects the presentation it is given, and Interrupt follows the
/// availability it is given.
@MainActor
struct LeoAgentToolbarTrailingTests {
    private struct Fixture {
        let window: NSWindow
        let toolbar: LeoAgentToolbar
        let presentation = PassthroughSubject<LeoViewSwitchPresentation, Never>()
        let interruptEnabled = PassthroughSubject<Bool, Never>()
        let selections = Selections()

        final class Selections { var chosen: [LeoAgentViewChoice] = [] }

        var items: [NSToolbarItem] { window.toolbar?.items ?? [] }
        func item(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? { items.first { $0.itemIdentifier == identifier } }
        var switchControl: LeoToolbarViewSwitch? { item(.leoViewSwitch)?.view as? LeoToolbarViewSwitch }
        var interrupt: NSToolbarItem? { item(.leoInterrupt) }
    }

    private static func interruptMenu() -> NSMenu {
        let menu = NSMenu()
        let submenu = NSMenu()
        let interrupt = NSMenuItem(title: "Interrupt", action: #selector(TerminalController.interruptSelectedLeoAgent(_:)), keyEquivalent: ".")
        interrupt.keyEquivalentModifierMask = [.control, .command]
        submenu.addItem(interrupt)
        let agents = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        agents.submenu = submenu
        menu.addItem(agents)
        return menu
    }

    private static func makeFixture(mainMenu: NSMenu? = nil) -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 600))
        let toolbar = LeoAgentToolbar()
        toolbar.makeActivityView = { NSView() }
        toolbar.mainMenu = { mainMenu }
        toolbar.install(on: window)
        let fixture = Fixture(window: window, toolbar: toolbar)
        toolbar.bind(viewSwitch: fixture.presentation, select: { [selections = fixture.selections] in selections.chosen.append($0) })
        toolbar.bind(interruptEnabled: fixture.interruptEnabled)
        return fixture
    }

    @Test func theTrailingItemsComeLastInOrder() {
        let order = LeoAgentToolbar.itemOrder
        #expect(Array(order.suffix(3)) == [.leoViewSwitch, .leoInterrupt, .leoMore])
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        let ids = fixture.items.map(\.itemIdentifier)
        #expect(Array(ids.suffix(3)) == [.leoViewSwitch, .leoInterrupt, .leoMore], "\(ids.map(\.rawValue))")
    }

    @Test func theTrailingItemsAreNeverHidden() {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        for identifier in [NSToolbarItem.Identifier.leoViewSwitch, .leoInterrupt, .leoMore] {
            let item = fixture.item(identifier)
            #expect(item != nil && item?.isHidden == false && item?.visibilityPriority == .user, "\(identifier.rawValue)")
        }
    }

    // MARK: Interrupt

    @Test func interruptIsPresentAndDisabledWithNoAgent() throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        let interrupt = try #require(fixture.interrupt)

        #expect(!interrupt.isEnabled)
        #expect(interrupt.action == #selector(TerminalController.interruptSelectedLeoAgent(_:)))
        #expect(interrupt.target == nil)
    }

    @Test func interruptsTooltipNamesTheLiveShortcut() throws {
        let fixture = Self.makeFixture(mainMenu: Self.interruptMenu())
        defer { fixture.window.close() }

        #expect(try #require(fixture.interrupt).toolTip == "Interrupt (⌃⌘.)")
    }

    @Test func interruptsTooltipIsPlainWithoutAShortcut() throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }

        #expect(try #require(fixture.interrupt).toolTip == "Interrupt")
    }

    @Test func interruptFollowsTheAvailabilityItIsGiven() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        let interrupt = try #require(fixture.interrupt)

        fixture.interruptEnabled.send(true)
        await settle()
        #expect(interrupt.isEnabled, "the agent started working but Interrupt stayed disabled")

        fixture.interruptEnabled.send(false)
        await settle()
        #expect(!interrupt.isEnabled, "the agent went idle but Interrupt stayed enabled")
    }

    @Test func interruptStartsDisabledEvenWhenTheItemIsBuiltAfterTheBinding() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        fixture.interruptEnabled.send(true)
        await settle()

        // A toolbar rebuilt later (a second item instance) starts from what the binding last said.
        let rebuilt = fixture.toolbar.toolbar(
            try #require(fixture.window.toolbar), itemForItemIdentifier: .leoInterrupt, willBeInsertedIntoToolbar: true)
        #expect(rebuilt?.isEnabled == true)
    }

    // MARK: View switch

    @Test func theSwitchStartsDisabledWithNothingLit() throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        let control = try #require(fixture.switchControl)

        #expect(!control.isEnabled)
        #expect(!control.isSelected(forSegment: 0) && !control.isSelected(forSegment: 1))
        #expect(control.segmentCount == 2)
    }

    @Test func theSwitchReflectsAPushedPresentation() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        let control = try #require(fixture.switchControl)

        fixture.presentation.send(LeoViewSwitchPresentation(layout: .sideBySide, unreadCount: 0))
        await settle()
        #expect(control.isEnabled)
        #expect(control.isSelected(forSegment: 0) && control.isSelected(forSegment: 1))
        #expect(!control.showsUnreadDot)

        fixture.presentation.send(LeoViewSwitchPresentation(layout: .terminal, unreadCount: 2))
        await settle()
        #expect(control.isSelected(forSegment: 0) && !control.isSelected(forSegment: 1))
        #expect(control.showsUnreadDot)
        #expect(control.image(forSegment: 1)?.accessibilityDescription == "Chat, 2 unread")
        #expect(control.image(forSegment: 0)?.accessibilityDescription == "Terminal")
        #expect(control.toolTip(forSegment: 0) == "Terminal" && control.toolTip(forSegment: 1) == "Chat")
        #expect(control.accessibilityLabel() == "View")

        fixture.presentation.send(LeoViewSwitchPresentation(layout: .chatReplacingTerminal, unreadCount: 2))
        await settle()
        #expect(!control.showsUnreadDot)
        #expect(control.image(forSegment: 1)?.accessibilityDescription == "Chat")
    }

    @Test func theUnreadDotChangesTheChatSegmentsImage() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        let control = try #require(fixture.switchControl)

        fixture.presentation.send(LeoViewSwitchPresentation(layout: .terminal, unreadCount: 0))
        await settle()
        let plain = try #require(control.image(forSegment: 1)?.tiffRepresentation)
        fixture.presentation.send(LeoViewSwitchPresentation(layout: .terminal, unreadCount: 1))
        await settle()
        let dotted = try #require(control.image(forSegment: 1)?.tiffRepresentation)

        #expect(plain != dotted)
    }

    @Test func clickingTheChatSegmentSelectsChat() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        let control = try #require(fixture.switchControl)
        fixture.presentation.send(LeoViewSwitchPresentation(layout: .terminal, unreadCount: 0))
        await settle()

        // `.selectAny`: the click flips the segment before the action fires.
        control.setSelected(true, forSegment: 1)
        _ = control.sendAction(control.action, to: control.target)

        #expect(fixture.selections.chosen == [.chat])
        // The control snaps back to what is shown until the session changes it.
        #expect(!control.isSelected(forSegment: 1))
    }

    @Test func theSwitchNeverTakesFocusFromTheTerminal() throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        let control = try #require(fixture.switchControl)

        #expect(control.refusesFirstResponder)
        #expect(!control.acceptsFirstResponder)
    }

    /// Publisher sinks receive on the main queue: let it drain.
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
    }
}
