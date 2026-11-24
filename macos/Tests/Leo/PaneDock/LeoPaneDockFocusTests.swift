import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-439: View ▸ Dock Focused Pane acts on the pane holding keyboard focus,
/// found up the responder chain from the first responder.
@MainActor
struct LeoPaneDockFocusTests {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)

    init() {
        window.isReleasedWhenClosed = false
    }

    private func host(_ controller: NSViewController) {
        window.contentViewController = controller
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The page sits in the browser's pane inside a strip that also holds
    /// Files' tabs: the browser is the nearer owner.
    @Test func focusInsideTheWebViewTargetsTheBrowser() {
        defer { window.close() }
        let strip = LeoEditorTabsViewController(tabs: LeoEditorTabs(makeAccess: LeoWindowSession.noFileAccess))
        let browser = LeoAgentBrowserPaneViewController(source: FakePaneSource())
        strip.addChild(browser)
        host(strip)
        strip.view.addSubview(browser.view)
        let page = NSView()
        browser.pageSlot.addSubview(page)

        #expect(LeoPaneDockFocus.pane(for: page) == .browser)
        #expect(LeoPaneDockFocus.pane(for: browser.toolbar) == .browser)
    }

    @Test func focusInTheOutlineOrEditorTargetsFiles() {
        defer { window.close() }
        let tabs = LeoEditorTabs(makeAccess: LeoWindowSession.noFileAccess)
        let outline = LeoWorkspaceBrowserViewController(
            model: LeoWorkspaceBrowserModel(makeAccess: LeoWindowSession.noFileAccess) { try await tabs.open($0) })
        let strip = LeoEditorTabsViewController(tabs: tabs)
        let column = NSViewController()
        column.view = NSView()
        column.addChild(outline)
        column.addChild(strip)
        host(column)
        column.view.addSubview(outline.view)
        column.view.addSubview(strip.view)
        let text = NSTextView()
        strip.view.addSubview(text)

        #expect(LeoPaneDockFocus.pane(for: outline.outlineView) == .files)
        #expect(LeoPaneDockFocus.pane(for: text) == .files)
    }

    /// A field's editor stands for its field: focus in the browser's address bar is the browser's.
    @Test func aFieldEditorCountsAsItsField() throws {
        defer { window.close() }
        let browser = LeoAgentBrowserPaneViewController(source: FakePaneSource())
        host(browser)
        let field = NSTextField()
        browser.view.addSubview(field)
        try #require(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSText)
        try #require(editor.isFieldEditor)

        #expect(LeoPaneDockFocus.pane(for: editor) == .browser)
    }

    @Test func focusInTheTerminalTargetsNoPane() {
        defer { window.close() }
        let terminal = NSViewController()
        terminal.view = NSView()
        host(terminal)
        let surface = NSView()
        terminal.view.addSubview(surface)

        #expect(LeoPaneDockFocus.pane(for: surface) == nil)
        #expect(LeoPaneDockFocus.pane(for: window) == nil)
        #expect(LeoPaneDockFocus.pane(for: nil) == nil)
    }
}
