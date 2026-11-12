import Testing

@testable import LeoKit

struct LeoPluginSectionRowsTests {
    private func item(_ id: String, _ title: String = "t") -> LeoPluginNode.Item { .init(id: id, title: title) }
    private func list(_ sections: [LeoPluginNode.Section]) -> LeoPluginNode { .list(.init(sections: sections)) }

    @Test func aSingleSectionListDrawsItsItemsWithoutItsTitle() {
        let rows = LeoPluginSectionRows.make(from: [list([.init(title: "Recent", items: [item("a"), item("b")])])])
        #expect(rows.map(\.id) == ["0.0.a", "0.0.b"])
        #expect(rows.allSatisfy { if case .item = $0 { true } else { false } })
    }

    @Test func severalSectionsKeepTheirTitlesAsSubheaders() {
        let rows = LeoPluginSectionRows.make(from: [list([
            .init(title: "Open", items: [item("a")]), .init(title: "Closed", items: [item("a")]), .init(items: [item("c")]),
        ])])
        #expect(rows.map(\.id) == ["h0.0", "0.0.a", "h0.1", "0.1.a", "0.2.c"])
    }

    @Test func anEmptyStateIsOneMessageRow() {
        let rows = LeoPluginSectionRows.make(from: [.emptyState(.init(title: "All clear", message: "Nothing assigned"))])
        #expect(rows == [.message(id: "n0", title: "All clear", detail: "Nothing assigned")])
    }

    @Test func aDetailShowsItsPlainTextAsOneMessageRow() {
        let rows = LeoPluginSectionRows.make(from: [.detail(.init(markdown: "# Heading\n\nSome **bold** body"))])
        #expect(rows.count == 1)
        if case .message(_, let title, _) = rows[0] { #expect(title == "Heading") } else { Issue.record("expected a message row") }
    }

    @Test func componentsASidebarCantShowDrawNothingAndAnEmptyTreeSaysSo() {
        #expect(LeoPluginSectionRows.make(from: [.accessory(.init(text: "x"))]) == [.message(id: "empty", title: "Nothing to show", detail: nil)])
        #expect(LeoPluginSectionRows.make(from: []) == [.message(id: "empty", title: "Nothing to show", detail: nil)])
    }

    @Test func aListWithNoItemsSaysNothingToShow() {
        #expect(LeoPluginSectionRows.make(from: [list([.init(items: [])])]) == [.message(id: "empty", title: "Nothing to show", detail: nil)])
    }

    @Test func rowsOfSeveralNodesKeepUniqueIDs() {
        let rows = LeoPluginSectionRows.make(from: [list([.init(items: [item("a")])]), list([.init(items: [item("a")])])])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func aTextIsOneMessageRowOfItsRunsAndAMeterDrawsNothing() {
        let text = LeoPluginNode.text(.init(runs: [.init(text: "Opus ", tone: .accent1), .init(text: "62%")]))
        #expect(LeoPluginSectionRows.make(from: [text]) == [.message(id: "n0", title: "Opus 62%", detail: nil)])
        let meter = LeoPluginNode.meter(.init(segments: [.init(value: 1, tone: .success)], max: 2))
        #expect(LeoPluginSectionRows.make(from: [meter]) == [.message(id: "empty", title: "Nothing to show", detail: nil)])
    }
}
