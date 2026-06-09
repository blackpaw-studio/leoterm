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

    @Test(arguments: [
        (0, 0, 0), (1, 1, 1), (2, 1, 2), (3, 1, 3), (4, 2, 2),
        (5, 2, 3), (6, 2, 3), (7, 2, 4), (8, 2, 4), (9, 3, 3), (10, 3, 4),
    ])
    func dimensionsMatchPackingTable(n: Int, rows: Int, columns: Int) {
        let dims = GridLayout<MockCell>.dimensions(forCount: n)
        #expect(dims.rows == rows)
        #expect(dims.columns == columns)
    }

    @Test func dimensionsAreNeverTallerThanWide() {
        for n in 1...50 {
            let d = GridLayout<MockCell>.dimensions(forCount: n)
            #expect(d.columns >= d.rows)
            #expect(d.rows * d.columns >= n)
        }
    }

    @Test func instanceDimensionsTrackCellCount() {
        let layout = GridLayout(cells: (0..<6).map { _ in MockCell() })
        let d = layout.dimensions
        #expect(d.rows == 2 && d.columns == 3)
    }

    @Test func framesEmptyOrZeroSizeReturnsNothing() {
        #expect(GridLayout<MockCell>().frames(in: CGSize(width: 100, height: 100)).isEmpty)
        let one = GridLayout(cells: [MockCell()])
        #expect(one.frames(in: .zero).isEmpty)
    }

    @Test func framesSingleCellFillsBounds() {
        let cell = MockCell()
        let frames = GridLayout(cells: [cell]).frames(in: CGSize(width: 800, height: 600))
        #expect(frames.count == 1)
        #expect(frames[0].frame == CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test func framesThreeCellsAreOneRowOfEqualThirds() {
        let cells = (0..<3).map { _ in MockCell() }
        let frames = GridLayout(cells: cells).frames(in: CGSize(width: 300, height: 100))
        #expect(frames.count == 3)
        #expect(frames.map { $0.frame } == [
            CGRect(x: 0,   y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
            CGRect(x: 200, y: 0, width: 100, height: 100),
        ])
    }

    @Test func framesLastPartialRowStretchesAcrossFullWidth() {
        let cells = (0..<5).map { _ in MockCell() }
        let frames = GridLayout(cells: cells)
            .frames(in: CGSize(width: 300, height: 200)).map { $0.frame }
        #expect(frames[0] == CGRect(x: 0,   y: 0,   width: 100, height: 100))
        #expect(frames[2] == CGRect(x: 200, y: 0,   width: 100, height: 100))
        #expect(frames[3] == CGRect(x: 0,   y: 100, width: 150, height: 100))
        #expect(frames[4] == CGRect(x: 150, y: 100, width: 150, height: 100))
    }

    @Test func framesApplyGapBetweenCells() {
        let cells = (0..<2).map { _ in MockCell() }
        let frames = GridLayout(cells: cells)
            .frames(in: CGSize(width: 210, height: 100), gap: 10).map { $0.frame }
        #expect(frames[0] == CGRect(x: 0,   y: 0, width: 100, height: 100))
        #expect(frames[1] == CGRect(x: 110, y: 0, width: 100, height: 100))
    }

    @Test func framesPreserveCellIdentityAndOrder() {
        let cells = (0..<4).map { _ in MockCell() }
        let frames = GridLayout(cells: cells).frames(in: CGSize(width: 200, height: 200))
        #expect(frames.map { $0.cell.id } == cells.map { $0.id })
    }
}
