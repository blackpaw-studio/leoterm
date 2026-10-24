import Testing

@testable import Leo

struct KeyValueRowsTests {
    @Test func rowsStartSortedByName() {
        let rows = KeyValueRows(entries: ["B": "2", "A": "1"])

        #expect(rows.rows.map(\.key) == ["A", "B"])
    }

    @Test func aNewRowKeepsItsPlaceWhileTheNameIsEmptyOrDuplicate() {
        var rows = KeyValueRows(entries: ["A": "1"])
        rows.add()
        rows.add()
        rows.setKey("A", at: 2)

        #expect(rows.rows.map(\.key) == ["A", "", "A"])
        #expect(rows.entries == ["A": "", "": ""])
    }

    @Test func theLastDuplicateWins() {
        var rows = KeyValueRows(entries: ["A": "1"])
        rows.add()
        rows.setKey("A", at: 1)
        rows.setValue("2", at: 1)

        #expect(rows.entries == ["A": "2"])
    }

    @Test func removingARowDropsItsEntry() {
        var rows = KeyValueRows(entries: ["A": "1", "B": "2"])

        rows.remove(at: 0)

        #expect(rows.entries == ["B": "2"])
    }

    @Test func anExternalChangeReplacesTheRowsOnlyWhenTheMapDiffers() {
        var rows = KeyValueRows(entries: ["A": "1"])
        rows.add()

        rows.reset(to: ["A": "1", "": ""])
        #expect(rows.rows.map(\.key) == ["A", ""])

        rows.reset(to: ["Z": "9"])
        #expect(rows.rows.map(\.key) == ["Z"])
    }
}
