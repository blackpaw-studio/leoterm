import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

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

    /// B-153: how far the header controls' drawn glyphs may sit from the
    /// shared line, and from each other: one backing pixel at 1x, which the
    /// headless test host renders at (an odd-sized glyph lands half a point
    /// off a whole-point line there).
    private static let centreTolerance: CGFloat = 0.5

    @Test func theHiddenStyleInsetsTheSidePaneHeadersLikeTheSidebarHeader() async throws {
        let fixture = try await StyledWindowFixture.make(.hidden)
        defer { fixture.close() }
        // Measured before the panes open: that resizes the window.
        let sidebarTop = fixture.windowTop - fixture.header.maxY
        let sidebarView = try #require(fixture.split.sidebarItem?.viewController.view, "no sidebar view")
        let plus = try #require(
            InkBounds.measure(sidebarView, in: sidebarView.convert(fixture.accessory, from: nil).insetBy(dx: -3, dy: -3)),
            "the sidebar + button draws nothing")
        let sidebarButtonCentre = fixture.windowTop - plus.midY
        let panes = try await SidePaneHeaders.measure(in: fixture, size: Self.windowSize)
        // Absolute: the sidebar bound above ties the panes to the window's
        // top edge only through the sidebar header (B-151).
        let expectedCentre = LeoSidebarChromeMetrics.topInset + LeoSidebarChromeMetrics.headerRowHeight / 2

        // B-153: the sidebar's + and both close glyphs, as drawn, share one
        // centre line: the one the metrics put them on, and each other's.
        // (The + was measured before the window resized above.)
        #expect(
            abs(sidebarButtonCentre - expectedCentre) <= Self.centreTolerance,
            "the sidebar + button centres \(sidebarButtonCentre) pt under the window's top edge, not \(expectedCentre); \(panes)"
        )
        let centres = [sidebarButtonCentre] + panes.all.map { fixture.windowTop - $0.glyph.midY }
        let spread = (centres.max() ?? 0) - (centres.min() ?? 0)
        #expect(
            spread <= Self.centreTolerance,
            "the sidebar + (\(sidebarButtonCentre)), browser and editor close glyphs centre \(centres) pt under the window's top edge, \(spread) pt apart; \(panes)"
        )
        for pane in panes.all {
            let top = fixture.windowTop - pane.glyph.maxY
            let centre = fixture.windowTop - pane.glyph.midY
            #expect(
                abs(centre - expectedCentre) <= Self.centreTolerance,
                "the \(pane.name) close glyph centres \(centre) pt under the window's top edge, not the inset + half a header row, \(expectedCentre); \(panes)"
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
