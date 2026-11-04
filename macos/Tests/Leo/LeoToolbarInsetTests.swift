import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// The toolbar's real height, read from the window, replaces the fixed
/// titlebar inset (so full screen, which releases the toolbar, releases it
/// too).
@MainActor
struct LeoToolbarInsetTests {
    @Test func theInsetIsTheGapBetweenTheWindowTopAndTheContentLayoutRect() {
        #expect(LeoToolbarInset.height(contentHeight: 600, contentLayoutMaxY: 548) == 52)
    }

    @Test func fullScreenAtRestHasNoInset() {
        #expect(LeoToolbarInset.height(contentHeight: 900, contentLayoutMaxY: 900) == 0)
    }

    @Test func aNegativeGapClampsToZero() {
        #expect(LeoToolbarInset.height(contentHeight: 600, contentLayoutMaxY: 640) == 0)
    }

    @Test func theHeaderLineIsTheChromeInsetBelowTheToolbar() {
        let inset = LeoToolbarInset(height: 52)
        #expect(inset.headerTop == 52 + LeoSidebarChromeMetrics.topInset)
    }
}
