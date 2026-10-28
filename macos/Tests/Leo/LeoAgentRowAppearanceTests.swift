import AppKit
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The Mac row: a 3pt color bar (or a blank slot of the same width) on the
/// trailing edge, after the name line, and the emoji before the name. The sizes are logic; the drawing is a TDD exception.
struct LeoAgentRowAppearanceTests {
    private func row(_ appearance: LeoAgentAppearance?, name: String = "olympus", status: LeoAgentStatus = .running) -> LeoAgentRow {
        LeoAgentRow(
            host: .local, name: name, template: "ops", status: status, activity: .idle, actionDetail: nil, appearance: appearance
        )
    }

    @Test func nameColumnInsetExcludesTheTrailingBarSlot() {
        #expect(LeoAgentRowMetrics.colorBarWidth == 3)
        #expect(LeoAgentRowMetrics.colorBarSlot == LeoAgentRowMetrics.colorBarWidth + LeoAgentRowMetrics.colorBarSpacing)
        #expect(LeoAgentRowMetrics.nameColumnInset
            == LeoAgentRowMetrics.symbolColumnWidth + LeoAgentRowMetrics.symbolSpacing)
    }

    @Test func oneLineRowIsStill24pt() {
        #expect(LeoAgentRowMetrics.nameLineHeight + 2 * LeoAgentRowMetrics.verticalPadding == 24)
    }

    @Test func presentationCarriesTheAppearance() {
        let both = LeoAgentRowPresentation(row: row(LeoAgentAppearance(emoji: "🏛️", color: .teal)), error: nil)
        #expect(both.leadingEmoji == "🏛️")
        #expect(both.barColor == .teal)
        let neither = LeoAgentRowPresentation(row: row(nil), error: nil)
        #expect(neither.leadingEmoji == nil)
        #expect(neither.barColor == nil)
    }

    @Test func appearanceNeverChangesTheStateOrDetail() {
        let plain = LeoAgentRowPresentation(row: row(nil, status: .stopped), error: nil)
        let styled = LeoAgentRowPresentation(row: row(LeoAgentAppearance(emoji: "🎩", color: .pink), status: .stopped), error: nil)
        #expect(styled.state == plain.state)
        #expect(styled.detail == plain.detail)
        #expect(styled.isNameDimmed == plain.isNameDimmed)
    }

    @Test func accessibilityLabelAddsTheColorName() {
        let teal = LeoAgentRowPresentation(row: row(LeoAgentAppearance(emoji: "🏛️", color: .teal)), error: nil)
        let plain = LeoAgentRowPresentation(row: row(nil), error: nil)
        #expect(teal.accessibilityLabel(name: "olympus") == plain.accessibilityLabel(name: "olympus") + ", Teal")
    }

    @Test func highlightsStillIndexTheNameAlone() {
        let styled = row(LeoAgentAppearance(emoji: "🏛️", color: .teal))
        let plain = row(nil)
        #expect(LeoFuzzyMatcher.nameHighlights(for: styled, query: "lym") == LeoFuzzyMatcher.nameHighlights(for: plain, query: "lym"))
        #expect(LeoFuzzyMatcher.highlightRuns(name: styled.name, offsets: LeoFuzzyMatcher.nameHighlights(for: styled, query: "lym"))
            .map(\.text).joined() == "olympus")
    }

    @Test func everyPaletteNameHasASystemColor() {
        let colors = LeoAppearanceColor.allCases.map(\.nsColor)
        #expect(Set(colors.map { $0.description }).count == LeoAppearanceColor.allCases.count)
        #expect(LeoAppearanceColor.teal.nsColor == .systemTeal)
        #expect(LeoAppearanceColor.gray.nsColor == .systemGray)
    }
}
