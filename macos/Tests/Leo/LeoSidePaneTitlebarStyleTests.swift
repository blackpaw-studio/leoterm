import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-100, reworked for the agent toolbar: the side panes' header rows (the
/// workspace browser's and the editor's) against the toolbar. The split runs
/// to the window's top edge in every style (the glass sidebar goes under the
/// traffic lights), so the panes' headers take the sidebar header's line:
/// the chrome's top inset under the toolbar's bottom edge
/// (`contentLayoutRect`), and centre on it together (B-153, B-154).
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

    /// B-153: how far the header controls' drawn glyphs may sit from the
    /// shared line, and from each other: one backing pixel at 1x, which the
    /// headless test host renders at (an odd-sized glyph lands half a point
    /// off a whole-point line there).
    private static let centreTolerance: CGFloat = 0.5

    /// The sidebar's + and both close glyphs, as drawn, share one centre
    /// line: the chrome's top inset plus half a header row under the
    /// toolbar's bottom edge. The sidebar + (measured before the panes
    /// open, which resizes the window) is the reference; the absolute
    /// figure pins both, so a shift in the two together still fails.
    /// `.hostOnly`: hosted macos-26 centres the glyphs off the sidebar line, AppKit layout rather than ours.
    @Test(.hostOnly, arguments: TitlebarStyle.allCases)
    func sidePaneCloseGlyphsCentreOnTheSidebarHeaderLineUnderTheToolbar(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }
        let sidebarView = try #require(fixture.split.sidebarItem?.viewController.view, "no sidebar view")
        let plus = try #require(
            InkBounds.measure(sidebarView, in: sidebarView.convert(fixture.accessory, from: nil).insetBy(dx: -3, dy: -3)),
            "the sidebar + button draws nothing")
        let sidebarLine = fixture.titlebarBottom - plus.midY
        let panes = try await SidePaneHeaders.measure(in: fixture, size: Self.windowSize)
        let expectedLine = LeoSidebarChromeMetrics.topInset + LeoSidebarChromeMetrics.headerRowHeight / 2
        let splitTop = fixture.split.splitView.convert(fixture.split.splitView.bounds, to: nil).maxY

        #expect(splitTop == fixture.windowTop, "\(style): \(fixture.diagnostics)")
        #expect(
            abs(sidebarLine - expectedLine) <= Self.centreTolerance,
            "\(style): the sidebar + centres \(sidebarLine) pt under the toolbar, not \(expectedLine); \(panes)"
        )
        for pane in panes.all {
            let line = fixture.titlebarBottom - pane.glyph.midY
            #expect(
                abs(line - expectedLine) <= Self.centreTolerance,
                "\(style): the \(pane.name) close glyph centres \(line) pt under the toolbar, not \(expectedLine); \(panes)"
            )
        }
    }
}

/// One side pane's header: its row, and the ink its close button draws, in
/// window coordinates.
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
        // B-149: geometry read after run-loop turns may still be pre-layout.
        fixture.window.layoutIfNeeded()
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
        let glyph = try #require(InkBounds.measure(close, in: close.bounds), "\(name): the close button draws nothing")
        return SidePaneHeader(name: name, row: row.convert(row.bounds, to: nil), glyph: glyph)
    }

    private static func firstButton(in view: NSView, toolTip: String) -> NSButton? {
        if let button = view as? NSButton, button.toolTip == toolTip { return button }
        return view.subviews.lazy.compactMap { firstButton(in: $0, toolTip: toolTip) }.first
    }
}

/// Where a view actually draws, read from its rendered pixels: a control's
/// frame or `imageRect` says where AppKit meant to put a glyph, not where
/// its ink lands after pixel snapping (B-153).
@MainActor
private enum InkBounds {
    /// How far a channel may differ from the background before it counts as ink.
    private static let threshold: CGFloat = 0.1

    /// The tight window-coordinate bounds of what `view` draws inside `rect`
    /// (view coordinates) that differs from the pixel at the rect's top-left
    /// corner. Nil when nothing does, or the view can't be rendered.
    static func measure(_ view: NSView, in rect: CGRect) -> CGRect? {
        let rect = rect.intersection(view.bounds)
        guard !rect.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        guard let background = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return nil }
        let inked = (0 ..< rep.pixelsHigh).flatMap { y in
            (0 ..< rep.pixelsWide).filter { x in
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return [
                    pixel.alphaComponent - background.alphaComponent, pixel.redComponent - background.redComponent,
                    pixel.greenComponent - background.greenComponent, pixel.blueComponent - background.blueComponent,
                ].contains { abs($0) > threshold }
            }.map { (x: $0, y: y) }
        }
        guard let minX = inked.map(\.x).min(), let maxX = inked.map(\.x).max(),
              let minY = inked.map(\.y).min(), let maxY = inked.map(\.y).max() else { return nil }
        // Bitmap rows run top-down whatever the view's flippedness; window y runs up.
        let scale = CGFloat(rep.pixelsWide) / rect.width
        let window = view.convert(rect, to: nil)
        return CGRect(
            x: window.minX + CGFloat(minX) / scale, y: window.maxY - CGFloat(maxY + 1) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
