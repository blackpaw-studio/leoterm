import Testing

@testable import Ghostty

/// B-275: an agent and its dispatches read as one block.
struct LeoDispatchRowSpacingTests {
    @Test func agentAndDispatchesReadAsOneBlock() {
        let inside = max(LeoDispatchRowMetrics.agentToFirstGap, LeoDispatchRowMetrics.siblingGap)

        #expect(LeoDispatchRowMetrics.groupToNextAgentGap - inside >= LeoDispatchRowMetrics.minimumGroupContrast)
    }

    @Test func dispatchRowsSitNoMoreThan24ptApart() {
        #expect(LeoDispatchRowMetrics.pitch <= 24)
        #expect(LeoDispatchRowMetrics.pitch >= LeoDispatchRowMetrics.rowHeight)
    }

    @Test func theGapsAddUpFromTheRowGeometry() {
        #expect(LeoDispatchRowMetrics.agentToFirstGap == 9)
        #expect(LeoDispatchRowMetrics.siblingGap == 2)
        #expect(LeoDispatchRowMetrics.groupToNextAgentGap == 25)
    }
}
