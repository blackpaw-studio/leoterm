import AppKit
import Testing

@testable import Ghostty

struct LeoAgentPaneSplitTests {
    @Test
    func holdingPrioritiesStayInTheLowBandAndThePaneKeepsItsHeight() {
        let terminal = LeoAgentPaneSplitMetrics.terminalHoldingPriority
        let pane = LeoAgentPaneSplitMetrics.paneHoldingPriority
        #expect((250...260).contains(terminal.rawValue))
        #expect((250...260).contains(pane.rawValue))
        // Higher holds: the terminal absorbs a window resize, the pane keeps its height.
        #expect(pane > terminal)
    }

    @Test
    func collapsedThicknessIs30Both() {
        let limits = LeoAgentPaneSplitMetrics.limits(isExpanded: false, columnHeight: 800)
        #expect(limits.min == 30)
        #expect(limits.max == 30)
    }

    @Test
    func expandedLimitsAreTheDrawersMinAndHalfTheColumn() {
        let limits = LeoAgentPaneSplitMetrics.limits(isExpanded: true, columnHeight: 800)
        #expect(limits.min == 120)
        #expect(limits.max == 400)
    }

    @Test
    func aShortColumnNeverInvertsTheLimits() {
        let limits = LeoAgentPaneSplitMetrics.limits(isExpanded: true, columnHeight: 150)
        #expect(limits.min == 120)
        #expect(limits.max == 120)
    }

    @Test
    func theDividerPositionPutsThePaneAtItsDisplayedHeight() {
        // Pane height 184 in a 800-tall column: the divider sits 800 - 184 from the top.
        #expect(LeoAgentPaneSplitMetrics.dividerPosition(paneHeight: 184, columnHeight: 800, dividerThickness: 0) == 616)
        #expect(LeoAgentPaneSplitMetrics.dividerPosition(paneHeight: 184, columnHeight: 800, dividerThickness: 1) == 615)
    }

    @Test
    func theDrawersHeightIsReadBackFromTheDividerPosition() {
        #expect(LeoAgentPaneSplitMetrics.paneHeight(dividerPosition: 616, columnHeight: 800, dividerThickness: 0) == 184)
        #expect(LeoAgentPaneSplitMetrics.paneHeight(dividerPosition: 615, columnHeight: 800, dividerThickness: 1) == 184)
    }

    // MARK: Which divider moves are the user's

    @Test
    func aDragOfTheDividerInAStableColumnIsPersisted() {
        #expect(LeoAgentPaneSplitMetrics.shouldPersistHeight(
            height: 250, appliedHeight: 184, columnHeight: 800, previousColumnHeight: 800, isLiveResize: false))
    }

    @Test
    func aWindowShrinkClampIsNotAUserDrag() {
        // The column went 800 -> 400, so the 0.5x max clamp moves the pane from 300 to 200.
        #expect(!LeoAgentPaneSplitMetrics.shouldPersistHeight(
            height: 200, appliedHeight: 300, columnHeight: 400, previousColumnHeight: 800, isLiveResize: false))
    }

    @Test
    func nothingIsPersistedDuringAWindowLiveResize() {
        #expect(!LeoAgentPaneSplitMetrics.shouldPersistHeight(
            height: 250, appliedHeight: 184, columnHeight: 800, previousColumnHeight: 800, isLiveResize: true))
    }

    @Test
    func anUnchangedHeightOrOneBelowTheMinimumIsNotPersisted() {
        #expect(!LeoAgentPaneSplitMetrics.shouldPersistHeight(
            height: 184.2, appliedHeight: 184, columnHeight: 800, previousColumnHeight: 800, isLiveResize: false))
        #expect(!LeoAgentPaneSplitMetrics.shouldPersistHeight(
            height: 90, appliedHeight: 184, columnHeight: 800, previousColumnHeight: 800, isLiveResize: false))
    }

    @Test
    func theFirstNotificationHasNoPreviousColumnToCompareWith() {
        #expect(LeoAgentPaneSplitMetrics.shouldPersistHeight(
            height: 250, appliedHeight: 184, columnHeight: 800, previousColumnHeight: nil, isLiveResize: false))
    }
}
