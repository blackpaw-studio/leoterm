import Testing

@testable import Ghostty

/// The palette panel's height formula (header + row-height * row count,
/// clamped to [minHeight, maxHeight]) is pulled out into a pure enum so it
/// can be tested without a live window server. Row/header metrics should
/// match Mac list conventions (~32 pt rows), not the 44 pt iOS touch target.
struct LeoAgentPalettePanelLayoutTests {
    @Test func rowAndHeaderMetricsMatchMacListConventions() {
        #expect(LeoAgentPalettePanelLayout.rowHeight == 32)
        #expect(LeoAgentPalettePanelLayout.headerHeight == 52)
        #expect(LeoAgentPalettePanelLayout.width == 640)
    }

    @Test func zeroRowsClampsToMinHeight() {
        let height = LeoAgentPalettePanelLayout.panelHeight(rowCount: 0)

        #expect(height == LeoAgentPalettePanelLayout.minHeight)
    }

    @Test func oneRowUsesHeaderPlusOneRow() {
        let height = LeoAgentPalettePanelLayout.panelHeight(rowCount: 1)

        #expect(height == max(
            LeoAgentPalettePanelLayout.headerHeight + LeoAgentPalettePanelLayout.rowHeight,
            LeoAgentPalettePanelLayout.minHeight
        ))
    }

    @Test func manyRowsClampsToMaxHeight() {
        let height = LeoAgentPalettePanelLayout.panelHeight(rowCount: 100)

        #expect(height == LeoAgentPalettePanelLayout.maxHeight)
    }
}
