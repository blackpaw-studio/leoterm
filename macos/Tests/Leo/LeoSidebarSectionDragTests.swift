import Testing

@testable import Ghostty

/// B-438: a section header takes a drop only from a section drag this app
/// started; anything else dropped on it is refused.
@MainActor struct LeoSidebarSectionDragTests {
    @Test func dropRejectedWithoutAnInAppSectionDrag() {
        let drags = LeoSidebarSectionDrags()
        #expect(!drags.isDragging)
        #expect(drags.draggedKey(forPayload: "agents") == nil)
    }

    @Test func onlyTheCurrentDragsPayloadIsAccepted() {
        let drags = LeoSidebarSectionDrags()
        let first = drags.begin(LeoSidebarSectionOrder.terminals)
        let second = drags.begin(LeoSidebarSectionOrder.agents)
        #expect(drags.draggedKey(forPayload: first) == nil, "an older drag's payload")
        #expect(drags.draggedKey(forPayload: LeoSidebarSectionOrder.agents) == nil, "a bare key, as another app could send")
        #expect(drags.draggedKey(forPayload: second) == LeoSidebarSectionOrder.agents)
    }

    @Test func aDropEndsTheDrag() {
        let drags = LeoSidebarSectionDrags()
        let payload = drags.begin(LeoSidebarSectionOrder.terminals)
        drags.end()
        #expect(!drags.isDragging)
        #expect(drags.draggedKey(forPayload: payload) == nil)
    }
}
