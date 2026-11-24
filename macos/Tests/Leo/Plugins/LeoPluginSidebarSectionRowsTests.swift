import Testing

import LeoKit
@testable import Ghostty

/// B-438: a plugin section's table rows are its header plus one row per
/// entry it lists (`LeoPluginSectionListing`, which its rows view draws).
/// When a plugin section sits above Agents or Terminals, the off-screen
/// indicator and the Terminals-close landing count past these rows.
@MainActor struct LeoPluginSidebarSectionRowsTests {
    private func rows(_ content: LeoPluginSlotContent?) -> Int {
        LeoPluginSidebarSection.tableRows(listing: content)
    }

    @Test func aCollapsedSectionIsOnlyItsHeader() {
        #expect(LeoPluginSectionListing.rows(for: nil).isEmpty)
        #expect(rows(nil) == 1)
    }

    @Test func loadingIsTheHeaderAndOneStatusRow() {
        #expect(LeoPluginSectionListing.rows(for: .loading) == [.loading])
        #expect(rows(.loading) == 2)
    }

    @Test func anErrorIsTheHeaderAndOneStatusRow() {
        #expect(LeoPluginSectionListing.rows(for: .error("Rate limited")) == [.error("Rate limited")])
        #expect(rows(.error("Rate limited")) == 2)
    }

    @Test func aNoticeIsTheHeaderAndOneStatusRow() {
        let notice = LeoPluginSlotContent.unavailableNotice
        #expect(LeoPluginSectionListing.rows(for: .notice(notice)) == [.notice(notice)])
        #expect(rows(.notice(notice)) == 2)
    }

    @Test func nodesAreTheHeaderAndEachSectionRow() {
        let item = { (id: String) in LeoPluginNode.Item(id: id, title: id) }
        let nodes: [LeoPluginNode] = [.list(.init(sections: [
            .init(title: "Open", items: [item("a"), item("b")]),
            .init(title: "Closed", items: [item("c")]),
        ]))]
        // Two subheaders (the list has several sections) and three items.
        let listed = LeoPluginSectionListing.rows(for: .nodes(nodes, isPushed: false))
        #expect(listed == LeoPluginSectionRows.make(from: nodes).map(LeoPluginSectionListing.row))
        #expect(listed.map(\.id) == ["row.h0.0", "row.0.0.a", "row.0.0.b", "row.h0.1", "row.0.1.c"])
        #expect(rows(.nodes(nodes, isPushed: false)) == 6)
        #expect(rows(.nodes([], isPushed: false)) == 2, "the Nothing to show row")
    }
}
