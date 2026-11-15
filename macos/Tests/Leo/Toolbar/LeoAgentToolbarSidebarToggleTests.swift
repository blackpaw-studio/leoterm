import AppKit
import Combine
import Testing

@testable import Ghostty

/// B-398: the sidebar toggle is always in the toolbar, first, before the
/// tracking separator, reads the menu's Show/Hide title and enabled state,
/// and a click sends the menu's action.
@MainActor
struct LeoAgentToolbarSidebarToggleTests {
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private struct Fixture {
        let window: NSWindow
        let toolbar: LeoAgentToolbar
        let sidebarVisible = PassthroughSubject<Bool, Never>()
        let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1100, height: 600))
        let state = Box(LeoMenuCommands.SidebarToggleState(title: "Hide Agents Sidebar", isEnabled: true))
        let sent = Box<[Selector]>([])

        var items: [NSToolbarItem] { window.toolbar?.items ?? [] }
        var toggle: NSToolbarItem? { items.first { $0.itemIdentifier == .leoSidebarToggle } }
    }

    private static func makeFixture(hidesItemsInPlace: Bool) -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 600))
        let toolbar = LeoAgentToolbar()
        toolbar.makeActivityView = { NSView() }
        toolbar.hidesItemsInPlace = hidesItemsInPlace
        toolbar.install(on: window)
        let fixture = Fixture(window: window, toolbar: toolbar)
        toolbar.bind(sidebarVisible: fixture.sidebarVisible)
        toolbar.sidebarToggleState = { [state = fixture.state] in state.value }
        toolbar.setToggleSender { [sent = fixture.sent] action, _ in sent.value.append(action) }
        return fixture
    }

    /// The bindings deliver on the main queue's next turn: wait for everything queued before this.
    private func drain() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test(arguments: [true, false])
    func theToggleStaysWhileTheSidebarIsShown(hidesItemsInPlace: Bool) async throws {
        let fixture = Self.makeFixture(hidesItemsInPlace: hidesItemsInPlace)
        defer { fixture.window.close() }
        fixture.sidebarVisible.send(true)
        await drain()
        let toggle = try #require(fixture.toggle, "\(fixture.items.map(\.itemIdentifier.rawValue))")
        #expect(!toggle.isHidden)
        #expect(fixture.items.first?.itemIdentifier == .leoSidebarToggle)
    }

    @Test(arguments: [true, false])
    func theToggleIsFirstBeforeTheSeparatorInBothStates(hidesItemsInPlace: Bool) async {
        for visible in [true, false] {
            let fixture = Self.makeFixture(hidesItemsInPlace: hidesItemsInPlace)
            defer { fixture.window.close() }
            fixture.sidebarVisible.send(visible)
            await drain()
            fixture.toolbar.attach(splitView: fixture.splitView)
            let ids = fixture.items.map(\.itemIdentifier)
            #expect(ids.prefix(2).elementsEqual([.leoSidebarToggle, .leoSplitSeparator]), "visible=\(visible) \(ids.map(\.rawValue))")
        }
    }

    @Test(arguments: [true, false])
    func theToggleReadsTheMenuTitle(hidesItemsInPlace: Bool) async throws {
        let fixture = Self.makeFixture(hidesItemsInPlace: hidesItemsInPlace)
        defer { fixture.window.close() }
        let toggle = try #require(fixture.toggle)
        toggle.validate()
        #expect(toggle.toolTip == "Hide Agents Sidebar")
        #expect(toggle.label == "Hide Agents Sidebar")
        #expect(toggle.image?.accessibilityDescription == "Hide Agents Sidebar")
        fixture.state.value = .init(title: "Show Agents Sidebar", isEnabled: true)
        toggle.validate()
        #expect(toggle.toolTip == "Show Agents Sidebar")
        #expect(toggle.label == "Show Agents Sidebar")
        #expect(toggle.image?.accessibilityDescription == "Show Agents Sidebar")
    }

    @Test func theToggleDisablesWithTheMenu() throws {
        let fixture = Self.makeFixture(hidesItemsInPlace: true)
        defer { fixture.window.close() }
        let toggle = try #require(fixture.toggle)
        fixture.state.value = .init(title: "Show Agents Sidebar", isEnabled: false)
        toggle.validate()
        #expect(!toggle.isEnabled)
        fixture.state.value = .init(title: "Show Agents Sidebar", isEnabled: true)
        toggle.validate()
        #expect(toggle.isEnabled)
    }

    @Test func theToggleUsesTheSidebarLeftGlyph() throws {
        let fixture = Self.makeFixture(hidesItemsInPlace: true)
        defer { fixture.window.close() }
        let toggle = try #require(fixture.toggle)
        toggle.validate()
        let image = try #require(toggle.image)
        let expected = try #require(NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil))
        #expect(image.tiffRepresentation == expected.tiffRepresentation)
    }

    @Test func clickingTheToggleSendsTheMenuAction() throws {
        let fixture = Self.makeFixture(hidesItemsInPlace: true)
        defer { fixture.window.close() }
        let toggle = try #require(fixture.toggle)
        let action = try #require(toggle.action)
        #expect(NSApp.sendAction(action, to: toggle.target, from: toggle))
        #expect(fixture.sent.value == [#selector(TerminalController.toggleLeoSidebar(_:))])
    }
}
