import Testing

@testable import Ghostty

/// The tree guide must meet across the gap the List leaves between rows, and
/// the first child's line must reach up to its parent.
struct LeoDispatchGuideGeometryTests {
    private let rowHeight = LeoDispatchRowView.rowHeight

    private func geometry(_ parent: LeoDispatchParentLink) -> LeoDispatchGuideGeometry {
        LeoDispatchGuideGeometry(rowHeight: rowHeight, parent: parent)
    }

    @Test func theElbowSitsAtTheRowsVerticalCentre() {
        for parent in [LeoDispatchParentLink.sibling, .dispatch, .agent] {
            let layout = geometry(parent)
            #expect(layout.midY == layout.topBleed + rowHeight / 2)
            #expect(layout.canvasHeight == layout.topBleed + rowHeight + layout.bottomBleed)
        }
    }

    @Test func aRowsLineAndTheNextRowsLineMeetAcrossTheListGap() {
        let gap = LeoDispatchGuideGeometry.listRowGap
        #expect(geometry(.sibling).bottomBleed + geometry(.sibling).topBleed >= gap)
        #expect(geometry(.dispatch).bottomBleed + geometry(.sibling).topBleed >= gap, "a parent's tee meets its first child")
    }

    @Test func aFirstChildReachesItsParent() {
        let gap = LeoDispatchGuideGeometry.listRowGap
        #expect(geometry(.dispatch).topBleed >= gap, "up to the parent dispatch row's bottom edge")
        #expect(geometry(.agent).topBleed >= gap + LeoAgentRowMetrics.verticalPadding, "up to the agent row's content bottom")
    }

    @Test func throughLinesSpanTheWholeCanvasAndAnElbowOnlyTheTopHalf() {
        let layout = geometry(.sibling)
        #expect(layout.throughLine == 0...layout.canvasHeight)
        #expect(layout.elbowLine == 0...layout.midY)
    }
}
