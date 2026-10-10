import Testing

@testable import Ghostty

/// The tree guide must meet across the gap between neighbouring rows' content
/// (B-275: 2pt), without overshooting it by more than the lines' overlap, and
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

    @Test func aRowsLineAndTheNextRowsLineMeetAcrossTheGap() {
        let gap = LeoDispatchRowMetrics.siblingGap
        let reach = geometry(.sibling).bottomBleed + geometry(.sibling).topBleed
        #expect(reach >= gap)
        #expect(reach <= gap + 2 * LeoDispatchGuideGeometry.overlap + 1, "no more than the overlap past the gap, plus rounding")
        #expect(geometry(.dispatch).bottomBleed + geometry(.sibling).topBleed >= gap, "a parent's tee meets its first child")
    }

    @Test func aFirstChildReachesItsParent() {
        #expect(geometry(.dispatch).topBleed >= LeoDispatchRowMetrics.siblingGap, "up to the parent dispatch row's bottom edge")
        #expect(geometry(.agent).topBleed >= LeoDispatchRowMetrics.agentToFirstGap, "up to the agent row's content bottom")
    }

    @Test func throughLinesSpanTheWholeCanvasAndAnElbowOnlyTheTopHalf() {
        let layout = geometry(.sibling)
        #expect(layout.throughLine == 0...layout.canvasHeight)
        #expect(layout.elbowLine == 0...layout.midY)
    }
}
