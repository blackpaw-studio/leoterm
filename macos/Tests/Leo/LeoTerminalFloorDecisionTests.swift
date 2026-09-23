import AppKit
import Testing

@testable import Ghostty

/// The terminal floor (D-036, D-058) as a pure decision: beside a side
/// pane, a narrowing window collapses the sidebar before the terminal goes
/// under its floor, then the side panes give way down to their minimums;
/// the sidebar isn't re-shown into a terminal it would squeeze.
struct LeoTerminalFloorDecisionTests {
    private typealias Metrics = LeoSidebarSplitMetrics
    private static let floor = LeoSidebarSplitMetrics.terminalFloor

    private func step(terminal: CGFloat, change: CGFloat, sidebar: Bool = true, sidePane: Bool = true) -> LeoSidebarSplitMetrics.FloorStep {
        Metrics.floorStep(terminalWidth: terminal, splitWidthChange: change, isSidebarShown: sidebar, isSidePaneShown: sidePane)
    }

    // MARK: Squeezing

    @Test func panesSqueezeTheTerminalOnlyUnderItsFloor() {
        // 1 000 - (200 + 180 + 320) - 3 dividers = 297.
        #expect(Metrics.squeezesTerminal(splitWidth: 1_000, paneWidths: [200, 180, 320], dividerThickness: 1))
        #expect(!Metrics.squeezesTerminal(splitWidth: 1_003, paneWidths: [200, 180, 320], dividerThickness: 1))
        #expect(!Metrics.squeezesTerminal(splitWidth: 301, paneWidths: [], dividerThickness: 1))
    }

    // MARK: Narrowing

    @Test func narrowingUnderTheFloorCollapsesTheSidebarFirst() {
        #expect(step(terminal: Self.floor - 4, change: -10) == .collapseSidebar)
    }

    @Test func withTheSidebarCollapsedTheSidePanesGiveWhatTheTerminalLacks() {
        #expect(step(terminal: Self.floor - 4, change: -10, sidebar: false) == .widenTerminal(by: 4))
    }

    @Test func narrowingAtOrAboveTheFloorChangesNothing() {
        #expect(step(terminal: Self.floor, change: -10) == .none)
        #expect(step(terminal: Self.floor + 4, change: -10, sidebar: false) == .none)
    }

    /// A divider drag, a pane opening or a widening window doesn't narrow
    /// the split: nothing is taken away from under the user's hand.
    @Test func aShortTerminalWithoutNarrowingChangesNothing() {
        #expect(step(terminal: 100, change: 0) == .none)
        #expect(step(terminal: 100, change: 40) == .none)
        #expect(step(terminal: 100, change: 0, sidebar: false) == .none)
    }

    /// Without a side pane there's no floor (D-036 is about side panes).
    @Test func withoutASidePaneNothingChanges() {
        #expect(step(terminal: 100, change: -10, sidePane: false) == .none)
        #expect(step(terminal: 100, change: -10, sidebar: false, sidePane: false) == .none)
    }
}
