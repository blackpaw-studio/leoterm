import AppKit
import Testing

@testable import Ghostty

/// B-105: whether the Terminals section -- the list's last rows -- shows in
/// what the list doesn't cover with a bar.
@MainActor struct LeoTerminalsViewportTests {
    private static let rowCount = 10
    private static let rowHeight: CGFloat = 20

    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { LeoTerminalsViewportTests.rowCount }
    }

    /// Ten 20 pt rows in a 100 pt list showing from `offset` down, with
    /// bars of `topBar` and `bottomBar` points over its top and bottom.
    /// The table holds its data source weakly, so the caller keeps `rows`.
    private static func list(
        showingFrom offset: CGFloat, topBar: CGFloat = 0, bottomBar: CGFloat = 0
    ) -> (scrollView: NSScrollView, rows: Rows) {
        let rows = Rows()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: CGFloat(rowCount) * rowHeight))
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.dataSource = rows
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = table
        scrollView.contentView.contentInsets = NSEdgeInsets(top: topBar, left: 0, bottom: bottomBar, right: 0)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: offset))
        table.reloadData()
        return (scrollView, rows)
    }

    @Test func lastRowsWithinTheListShow() {
        let list = Self.list(showingFrom: 100)
        #expect(LeoTerminalsViewport.showsLastRows(2, in: list.scrollView))
    }

    /// Rows 5-9 start where the list's bottom edge is: touching isn't showing.
    @Test func lastRowsBelowTheBottomEdgeDoNotShow() {
        let list = Self.list(showingFrom: 0)
        #expect(!LeoTerminalsViewport.showsLastRows(5, in: list.scrollView))
        #expect(LeoTerminalsViewport.showsLastRows(6, in: list.scrollView), "row 4 is on screen")
    }

    /// A 30 pt bar covers 170-200: the last row there doesn't show, the one
    /// above it does.
    @Test func aRowOnlyUnderABottomBarDoesNotShow() {
        let list = Self.list(showingFrom: 100, bottomBar: 30)
        #expect(!LeoTerminalsViewport.showsLastRows(1, in: list.scrollView))
        #expect(LeoTerminalsViewport.showsLastRows(2, in: list.scrollView))
    }

    @Test func noRowsOrMoreThanTheListHasDoNotShow() {
        let list = Self.list(showingFrom: 100)
        #expect(!LeoTerminalsViewport.showsLastRows(0, in: list.scrollView))
        #expect(!LeoTerminalsViewport.showsLastRows(Self.rowCount + 1, in: list.scrollView))
    }

    /// The list launches with its top bar's worth showing above the first
    /// row; scrolled down, its top goes back there.
    @Test func scrollToTopReachesTheTopPastTheInset() {
        let list = Self.list(showingFrom: 50, topBar: 10)
        LeoTerminalsViewport.scrollToTop(list.scrollView)
        #expect(list.scrollView.contentView.bounds.minY == -10)
    }

    /// Beside the finder: a table's scroll view under it, another table's
    /// elsewhere, and a scroll view under it with no table. The table's
    /// under it is the list.
    @Test func theFinderPicksTheOverlappingTableScrollView() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let finder = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let plain = Self.scrollView(frame: finder.frame, document: NSView())
        let elsewhere = Self.scrollView(frame: NSRect(x: 200, y: 0, width: 200, height: 300), document: NSTableView())
        let list = Self.scrollView(frame: finder.frame, document: NSTableView())
        [finder, plain, elsewhere, list].forEach(content.addSubview)

        let found = try #require(LeoTerminalsViewport.tableScrollView(behind: finder))
        #expect(found === list)
    }

    @Test func theFinderOutsideAWindowFindsNothing() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let finder = NSView(frame: container.bounds)
        container.addSubview(finder)
        container.addSubview(Self.scrollView(frame: container.bounds, document: NSTableView()))
        #expect(LeoTerminalsViewport.tableScrollView(behind: finder) == nil)
    }

    private static func scrollView(frame: NSRect, document: NSView) -> NSScrollView {
        let scrollView = NSScrollView(frame: frame)
        scrollView.documentView = document
        return scrollView
    }
}
