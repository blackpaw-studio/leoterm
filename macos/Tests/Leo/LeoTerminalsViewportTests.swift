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

    /// Ten 20 pt rows in a 100 pt list showing from `offset` down, with a
    /// bar of `bottomBar` points over its bottom. The table holds its data
    /// source weakly, so the caller keeps `rows`.
    private static func list(showingFrom offset: CGFloat, bottomBar: CGFloat = 0) -> (scrollView: NSScrollView, rows: Rows) {
        let rows = Rows()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: CGFloat(rowCount) * rowHeight))
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.dataSource = rows
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = table
        scrollView.contentView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomBar, right: 0)
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
}
