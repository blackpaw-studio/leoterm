import AppKit
import Testing

@testable import Ghostty

/// B-100: the side panes' header rows (the workspace browser's and the
/// editor's) against the window's top edge. In the hidden titlebar style
/// the split runs to the window's top edge (B-074, D-169), so their headers
/// take the sidebar header's top inset and centre on its line; in the
/// titled styles they stay where they were, flush under the titlebar.
///
/// Builds the window the way `LeoSidebarTitlebarStyleTests` does (a real
/// `TerminalController` on a config that sets only the style) and shows
/// both panes by expanding their split items: an empty pane lays its
/// header out the same as one with a file open. Each pane is measured by
/// its close button's glyph (the drawn symbol, not the button's padded
/// frame), the one control both headers always show.
@MainActor @Suite(.serialized)
struct LeoSidePaneTitlebarStyleTests {
    /// Room for every pane beside the sidebar and the terminal's floor, so
    /// no pane is squeezed or collapsed while it's measured.
    private static let windowSize = CGSize(width: 1600, height: 700)

    @Test func theHiddenStyleInsetsTheSidePaneHeadersLikeTheSidebarHeader() async throws {
        let fixture = try await StyledWindowFixture.make(.hidden)
        defer { fixture.close() }
        // Measured before the panes open: that resizes the window.
        let sidebarTop = fixture.windowTop - fixture.header.maxY
        let sidebarCentre = fixture.windowTop - fixture.header.midY
        let panes = try await SidePaneHeaders.measure(in: fixture, size: Self.windowSize)

        for pane in panes.all {
            let top = fixture.windowTop - pane.glyph.maxY
            let centre = fixture.windowTop - pane.glyph.midY
            #expect(
                abs(centre - sidebarCentre) <= 1,
                "the \(pane.name) header centres \(centre) pt under the window's top edge, the sidebar's \(sidebarCentre); \(panes)"
            )
            #expect(
                top >= sidebarTop - 1,
                "the \(pane.name) header rises above the sidebar's \(sidebarTop) pt inset to \(top) pt; \(panes)"
            )
        }
    }

    /// The titled styles keep the panes as they were: the header row starts
    /// at the split's top edge, under the titlebar.
    @Test(arguments: [TitlebarStyle.native, .transparent, .tabs])
    func titledStylesKeepTheSidePaneHeadersUnderTheTitlebar(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }
        let panes = try await SidePaneHeaders.measure(in: fixture, size: Self.windowSize)
        let splitTop = fixture.split.splitView.convert(fixture.split.splitView.bounds, to: nil).maxY

        #expect(splitTop == fixture.titlebarBottom, "\(style): \(fixture.diagnostics)")
        for pane in panes.all {
            #expect(pane.row.maxY == splitTop, "\(style): the \(pane.name) header row moved off the split's top edge; \(panes)")
        }
    }
}

/// One side pane's header: its row, and its close button's glyph, in window
/// coordinates.
private struct SidePaneHeader: CustomStringConvertible {
    let name: String
    let row: CGRect
    let glyph: CGRect

    var description: String { "\(name): row \(row) close glyph \(glyph)" }
}

/// Both side panes, shown and laid out in a fixture's window.
@MainActor
private struct SidePaneHeaders: CustomStringConvertible {
    let browser: SidePaneHeader
    let editor: SidePaneHeader

    var all: [SidePaneHeader] { [browser, editor] }
    var description: String { "\(browser); \(editor)" }

    static func measure(in fixture: StyledWindowFixture, size: CGSize) async throws -> SidePaneHeaders {
        fixture.window.setContentSize(size)
        let items = fixture.split.splitViewItems
        let browserItem = try #require(items.first { $0.leoPaneRole == .browser }, "no browser item")
        let editorItem = try #require(items.first { $0.leoPaneRole == .editor }, "no editor item")
        // B-273: the editor shows a tab's header once a file is open.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("leo-side-pane-\(UUID().uuidString).txt")
        try Data("a".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let tabs = try #require(fixture.controller.leoSession?.editor, "no editor tabs")
        try await tabs.open(LeoEditorFileID(host: .local, path: file.path), access: { _ in LeoFileAccessor.local() })
        browserItem.isCollapsed = false
        editorItem.isCollapsed = false
        for _ in 0 ..< 5 {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!browserItem.isCollapsed && !editorItem.isCollapsed, "a pane collapsed again")

        let browserClose = try #require(firstButton(in: browserItem.viewController.view, toolTip: "Close Files"), "no browser close button")
        // The editor item holds the pane of the row on screen (B-274), and
        // that its selected tab's (B-273).
        let editorView = try #require(editorItem.viewController.view.subviews.first?.subviews.first, "no editor pane")
        let editorRow = try #require(editorView.subviews.first { $0 is LeoEditorHeaderView }, "no editor header")
        let editorClose = try #require(firstButton(in: editorRow, toolTip: "Close Editor (⌘W)"), "no editor close button")
        return SidePaneHeaders(
            browser: try header("browser", row: try #require(browserClose.superview, "no browser header"), close: browserClose),
            editor: try header("editor", row: editorRow, close: editorClose))
    }

    private static func header(_ name: String, row: NSView, close: NSButton) throws -> SidePaneHeader {
        let cell = try #require(close.cell as? NSButtonCell, "\(name): the close button has no button cell")
        let glyph = cell.imageRect(forBounds: close.bounds)
        try #require(!glyph.isEmpty, "\(name): the close button draws no image")
        return SidePaneHeader(name: name, row: row.convert(row.bounds, to: nil), glyph: close.convert(glyph, to: nil))
    }

    private static func firstButton(in view: NSView, toolTip: String) -> NSButton? {
        if let button = view as? NSButton, button.toolTip == toolTip { return button }
        return view.subviews.lazy.compactMap { firstButton(in: $0, toolTip: toolTip) }.first
    }
}
