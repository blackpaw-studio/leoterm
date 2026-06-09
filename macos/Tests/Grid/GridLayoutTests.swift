import Testing
import Foundation
@testable import Ghostty

/// Minimal Identifiable stand-in for a cell, mirroring the MockView pattern
/// used by SplitTreeTests.
private struct MockCell: Identifiable, Equatable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

struct GridLayoutTests {
    @Test func emptyLayoutHasNoCells() {
        let layout = GridLayout<MockCell>()
        #expect(layout.cells.isEmpty)
    }

    @Test func countAndIsEmpty() {
        #expect(GridLayout<MockCell>().isEmpty)
        let layout = GridLayout(cells: [MockCell(), MockCell()])
        #expect(layout.count == 2)
        #expect(!layout.isEmpty)
    }

    @Test func appendingReturnsNewLayoutAndLeavesOriginalUnchanged() {
        let original = GridLayout<MockCell>()
        let cell = MockCell()
        let updated = original.appending(cell)
        #expect(original.isEmpty)
        #expect(updated.count == 1)
        #expect(updated.contains(id: cell.id))
    }

    @Test func removingByIdDropsOnlyThatCell() {
        let keep = MockCell()
        let drop = MockCell()
        let layout = GridLayout(cells: [keep, drop]).removing(id: drop.id)
        #expect(layout.count == 1)
        #expect(layout.contains(id: keep.id))
        #expect(!layout.contains(id: drop.id))
    }
}
