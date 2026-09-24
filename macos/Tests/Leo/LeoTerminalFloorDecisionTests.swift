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

    private func step(
        terminal: CGFloat, change: CGFloat, sidebar: Bool = true, sidePane: Bool = true,
        regrowth: CGFloat = 0, restorableSidebar: CGFloat? = nil
    ) -> LeoSidebarSplitMetrics.FloorStep {
        Metrics.floorStep(LeoSidebarSplitMetrics.FloorState(
            terminalWidth: terminal, splitWidthChange: change, isSidebarShown: sidebar, isSidePaneShown: sidePane,
            paneRegrowth: regrowth, restorableSidebarWidth: restorableSidebar))
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

    // MARK: Widening (D-059)

    /// What the side panes gave up comes back first, as far as the
    /// terminal has room above its floor.
    @Test func wideningGivesTheSqueezedPaneBackItsWidthFirst() {
        #expect(step(terminal: Self.floor + 5, change: 5, sidebar: false, regrowth: 200, restorableSidebar: 201) == .growPane(by: 5))
        #expect(step(terminal: Self.floor + 50, change: 5, sidebar: false, regrowth: 20) == .growPane(by: 20))
        #expect(step(terminal: Self.floor, change: 5, sidebar: false, regrowth: 20) == .none)
    }

    /// Then the sidebar the floor collapsed comes back, once the terminal
    /// keeps its floor plus some slack beside it -- so a window jiggled at
    /// the edge doesn't flip it back and forth.
    @Test func thenTheSidebarTheFloorCollapsedComesBackWithSlack() {
        let slack = Metrics.sidebarRestoreSlack
        #expect(slack > 2 * 5, "more than a live-resize step each way")
        #expect(step(terminal: Self.floor + 201 + slack, change: 5, sidebar: false, restorableSidebar: 201) == .restoreSidebar)
        #expect(step(terminal: Self.floor + 201 + slack - 1, change: 5, sidebar: false, restorableSidebar: 201) == .none)
        #expect(step(terminal: Self.floor + 500, change: 5, sidebar: false, sidePane: false, restorableSidebar: 201) == .restoreSidebar)
    }

    /// A sidebar the user hid (nothing to restore) stays hidden, and
    /// nothing comes back without the window widening.
    @Test func onlyWideningRestoresAndOnlyWhatTheFloorTook() {
        #expect(step(terminal: Self.floor + 500, change: 5, sidebar: false) == .none)
        #expect(step(terminal: Self.floor + 500, change: 0, sidebar: false, regrowth: 20, restorableSidebar: 201) == .none)
        #expect(step(terminal: Self.floor + 500, change: -5, sidebar: false, regrowth: 20, restorableSidebar: 201) == .none)
    }
}
