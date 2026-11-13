import AppKit
import Combine
import Testing

@testable import Ghostty

/// The tool toggles in a real toolbar: where they sit, what they show for
/// the state pushed to them, what a click sends, and the Browser toggle's
/// presence (including the macOS 14 insert/remove path).
@MainActor
struct LeoAgentToolbarToolsTests {
    private struct Fixture {
        let window: NSWindow
        let toolbar: LeoAgentToolbar
        let tools = PassthroughSubject<LeoToolbarToolState, Never>()
        let sent = Sent()

        final class Sent { var actions: [Selector] = [] }

        var items: [NSToolbarItem] { window.toolbar?.items ?? [] }
        func item(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
            items.first { $0.itemIdentifier == identifier }
        }
    }

    private static func makeFixture(hidesItemsInPlace: Bool? = nil) -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 600))
        let toolbar = LeoAgentToolbar()
        toolbar.makeActivityView = { NSView() }
        if let hidesItemsInPlace { toolbar.hidesItemsInPlace = hidesItemsInPlace }
        toolbar.install(on: window)
        let fixture = Fixture(window: window, toolbar: toolbar)
        toolbar.bind(tools: fixture.tools)
        toolbar.setToggleSender { [sent = fixture.sent] action, _ in sent.actions.append(action) }
        return fixture
    }

    /// Lit means the prominent style on macOS 26, an accent-tinted symbol before.
    private static func isLit(_ item: NSToolbarItem) -> Bool {
        if #available(macOS 26.0, *) { return item.style == .prominent }
        return item.image?.isTemplate == false
    }

    /// The bindings deliver on the main queue's next turn: wait for everything queued before this.
    private func drain() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func state(
        hasAgent: Bool = true, browserSettingOn: Bool = true, filesOpen: Bool = false, browserFront: Bool = false,
        paneExpanded: Bool = false
    ) -> LeoToolbarToolState {
        LeoToolbarToolState(
            hasAgent: hasAgent, browserSettingOn: browserSettingOn, filesOpen: filesOpen, browserFront: browserFront,
            editorHasTabs: false, paneShown: true, paneExpanded: paneExpanded)
    }

    @Test func theTogglesSitBeforeTheViewSwitchInOrder() async {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        let ids = fixture.items.map(\.itemIdentifier)
        let tail: [NSToolbarItem.Identifier] = [.leoFiles, .leoBrowser, .leoAgentPane, .leoViewSwitch, .leoInterrupt, .leoMore]
        #expect(Array(ids.suffix(tail.count)) == tail, "\(ids.map(\.rawValue))")
    }

    @Test func theTogglesFoldBeforeInterruptAndTheSwitch() async {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        for id in [NSToolbarItem.Identifier.leoFiles, .leoBrowser, .leoAgentPane] {
            #expect(fixture.item(id)?.visibilityPriority == .low, "\(id.rawValue)")
        }
    }

    @Test func eachToggleIsLitAndEnabledAsTheStateSays() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        fixture.tools.send(state(filesOpen: true, paneExpanded: true))
        await drain()
        let files = try #require(fixture.item(.leoFiles))
        let browser = try #require(fixture.item(.leoBrowser))
        let pane = try #require(fixture.item(.leoAgentPane))
        #expect(Self.isLit(files) && files.isEnabled)
        #expect(!Self.isLit(browser) && browser.isEnabled)
        #expect(Self.isLit(pane) && pane.isEnabled)
    }

    @Test func withNoAgentTheTogglesAreDisabledAndUnlit() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        fixture.tools.send(state(filesOpen: true))
        fixture.tools.send(state(hasAgent: false))
        await drain()
        for id in [NSToolbarItem.Identifier.leoFiles, .leoBrowser, .leoAgentPane] {
            let item = try #require(fixture.item(id))
            #expect(!item.isEnabled && !Self.isLit(item), "\(id.rawValue)")
        }
    }

    @Test func aClickSendsTheTogglesAction() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        fixture.tools.send(state())
        await drain()
        let files = try #require(fixture.item(.leoFiles))
        _ = files.target?.perform(files.action, with: files)
        #expect(fixture.sent.actions == [#selector(TerminalController.toggleLeoFilesPanel(_:))])
        #expect(!Self.isLit(files), "a click lights nothing: the panel's state does")
    }

    @Test func aLitToggleReadsAsHideInItsTooltip() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        fixture.tools.send(state(filesOpen: true))
        await drain()
        #expect(try #require(fixture.item(.leoFiles)).toolTip == "Hide Files")
        #expect(try #require(fixture.item(.leoBrowser)).toolTip == "Show Agent Browser")
    }

    @Test func theBrowserToggleIsHiddenWhenTheSettingIsOffAndBackWhenOn() async throws {
        let fixture = Self.makeFixture(hidesItemsInPlace: true)
        defer { fixture.window.close() }
        fixture.tools.send(state(browserSettingOn: false))
        await drain()
        #expect(try #require(fixture.item(.leoBrowser)).isHidden)
        fixture.tools.send(state(browserSettingOn: true))
        await drain()
        #expect(try #require(fixture.item(.leoBrowser)).isHidden == false)
    }

    @Test func theTogglesAndInterruptHideWhenTheWindowIsTooNarrowAndComeBackWhenWide() async throws {
        let fixture = Self.makeFixture(hidesItemsInPlace: true)
        defer { fixture.window.close() }
        fixture.window.setContentSize(NSSize(width: 1800, height: 600))
        fixture.window.layoutIfNeeded()
        for id in [NSToolbarItem.Identifier.leoFiles, .leoBrowser, .leoAgentPane, .leoInterrupt] {
            #expect(try #require(fixture.item(id)).isHidden == false, "wide \(id.rawValue)")
        }
        // Narrower: the toggles fold first, Interrupt stays.
        fixture.window.setContentSize(NSSize(width: 700, height: 600))
        fixture.window.layoutIfNeeded()
        for id in [NSToolbarItem.Identifier.leoFiles, .leoBrowser, .leoAgentPane] {
            #expect(try #require(fixture.item(id)).isHidden, "narrower \(id.rawValue)")
        }
        #expect(try #require(fixture.item(.leoInterrupt)).isHidden == false)
        fixture.window.setContentSize(NSSize(width: 650, height: 600))
        fixture.window.layoutIfNeeded()
        for id in [NSToolbarItem.Identifier.leoFiles, .leoBrowser, .leoAgentPane, .leoInterrupt] {
            #expect(try #require(fixture.item(id)).isHidden, "narrow \(id.rawValue)")
        }
        #expect(try #require(fixture.item(.leoViewSwitch)).isHidden == false)
        #expect(try #require(fixture.item(.leoMore)).isHidden == false)
        fixture.window.setContentSize(NSSize(width: 1800, height: 600))
        fixture.window.layoutIfNeeded()
        #expect(try #require(fixture.item(.leoFiles)).isHidden == false)
    }

    @Test func beforeMacOS15TheBrowserToggleIsRemovedAndInsertedBeforeThePane() async {
        let fixture = Self.makeFixture(hidesItemsInPlace: false)
        defer { fixture.window.close() }
        fixture.tools.send(state(browserSettingOn: false))
        await drain()
        #expect(fixture.item(.leoBrowser) == nil)
        fixture.tools.send(state(browserSettingOn: true))
        await drain()
        let ids = fixture.items.map(\.itemIdentifier)
        let filesAt = ids.firstIndex(of: .leoFiles)
        #expect(ids.firstIndex(of: .leoBrowser) == filesAt.map { $0 + 1 })
    }

    @Test func aToggleTheUserRemovedIsNotPutBackWhenTheSettingComesBack() async {
        let fixture = Self.makeFixture(hidesItemsInPlace: false)
        defer { fixture.window.close() }
        if let index = fixture.items.firstIndex(where: { $0.itemIdentifier == .leoBrowser }) { fixture.window.toolbar?.removeItem(at: index) }
        fixture.tools.send(state(browserSettingOn: false))
        await drain()
        fixture.tools.send(state(browserSettingOn: true))
        #expect(fixture.item(.leoBrowser) == nil)
    }
}
