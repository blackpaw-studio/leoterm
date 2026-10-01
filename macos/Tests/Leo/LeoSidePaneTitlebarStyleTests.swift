import AppKit
import Testing

@testable import Ghostty

/// B-100: the side panes' header rows (the workspace browser's and the
/// editor's) against the window's top edge. In the hidden titlebar style
/// the split runs to the window's top edge (B-074, D-169), so their headers
/// take the same top inset as the sidebar header; in the titled styles
/// they stay where they were, flush under the titlebar.
///
/// Builds the window the way `LeoSidebarTitlebarStyleTests` does (a real
/// `TerminalController` on a config that sets only the style) and shows
/// both panes by expanding their split items: an empty pane lays its
/// header out the same as one with a file open.
@MainActor @Suite(.serialized)
struct LeoSidePaneTitlebarStyleTests {
    /// Room for every pane beside the sidebar and the terminal's floor, so
    /// no pane is squeezed or collapsed while it's measured.
    private static let windowSize = CGSize(width: 1600, height: 700)

    @Test func theHiddenStyleInsetsTheSidePaneHeadersLikeTheSidebarHeader() async throws {
        let fixture = try await StyledWindowFixture.make(.hidden)
        defer { fixture.close() }
        let sidebarGap = fixture.windowTop - fixture.header.maxY
        let panes = try await SidePaneHeaders.measure(in: fixture, size: Self.windowSize)

        for pane in panes.all {
            let gap = fixture.windowTop - pane.controls.maxY
            #expect(
                abs(gap - sidebarGap) <= 1,
                "the \(pane.name) header sits \(gap) pt under the window's top edge, the sidebar's \(sidebarGap); \(panes)"
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

        for pane in panes.all {
            #expect(splitTop == fixture.titlebarBottom, "\(style): \(fixture.diagnostics)")
            #expect(pane.row.maxY == splitTop, "\(style): the \(pane.name) header row moved off the split's top edge; \(panes)")
        }
    }
}

/// One side pane's header: its row, and its visible controls' union, in
/// window coordinates.
private struct SidePaneHeader: CustomStringConvertible {
    let name: String
    let row: CGRect
    let controls: CGRect

    var description: String { "\(name): row \(row) controls \(controls)" }
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
        let browserItem = try #require(items.first { $0.viewController is LeoWorkspaceBrowserViewController }, "no browser item")
        let editorItem = try #require(items.first { $0.viewController is LeoEditorPaneViewController }, "no editor item")
        browserItem.isCollapsed = false
        editorItem.isCollapsed = false
        for _ in 0 ..< 5 {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!browserItem.isCollapsed && !editorItem.isCollapsed, "a pane collapsed again")

        let browserClose = try #require(firstButton(in: browserItem.viewController.view, toolTip: "Close Files"), "no browser close button")
        let browserRow = try #require(browserClose.superview, "no browser header")
        let editorRow = try #require(editorItem.viewController.view.subviews.first { $0 is LeoEditorHeaderView }, "no editor header")
        return SidePaneHeaders(
            browser: try header("browser", row: browserRow),
            editor: try header("editor", row: editorRow))
    }

    private static func header(_ name: String, row: NSView) throws -> SidePaneHeader {
        let controls = visibleControls(in: row).map { $0.convert($0.bounds, to: nil) }
        let union = try #require(controls.reduce(nil) { $0?.union($1) ?? $1 }, "\(name): no visible header controls")
        return SidePaneHeader(name: name, row: row.convert(row.bounds, to: nil), controls: union)
    }

    private static func firstButton(in view: NSView, toolTip: String) -> NSButton? {
        if let button = view as? NSButton, button.toolTip == toolTip { return button }
        return view.subviews.lazy.compactMap { firstButton(in: $0, toolTip: toolTip) }.first
    }

    /// The row's shown buttons and labels: what reads as the header.
    private static func visibleControls(in view: NSView) -> [NSView] {
        view.subviews.flatMap { subview -> [NSView] in
            guard !subview.isHidden else { return [] }
            if subview is NSControl, !subview.frame.isEmpty { return [subview] }
            return visibleControls(in: subview)
        }
    }
}
