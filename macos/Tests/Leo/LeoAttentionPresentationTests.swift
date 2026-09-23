import SwiftUI
import Testing

@testable import Ghostty

/// Row badges, VoiceOver text, Jump to Next Needing Attention and the Dock
/// label -- the pure decisions behind the attention UI.
struct LeoAttentionPresentationTests {
    private static let host = LeoHostID.local

    private struct ExpectedBadge {
        let badge: LeoAttentionBadge
        let symbol: String
        let color: NSColor
        let label: String
    }

    @Test func badgesUseTheSpecSymbolsColorsAndLabels() {
        let expected = [
            ExpectedBadge(badge: .working, symbol: "gearshape", color: .systemBlue, label: "Working"),
            ExpectedBadge(badge: .needsInput, symbol: "questionmark.circle", color: .systemOrange, label: "Needs Input"),
            ExpectedBadge(badge: .finished, symbol: "checkmark.circle", color: .systemGreen, label: "Finished"),
            ExpectedBadge(badge: .errored, symbol: "exclamationmark.triangle", color: .systemRed, label: "Errored")
        ]
        for item in expected {
            let presentation = LeoStatusPresentation.attention(item.badge)
            #expect(presentation.symbolName == item.symbol)
            #expect(presentation.color == Color(nsColor: item.color))
            #expect(presentation.accessibilityLabel == item.label)
        }
    }

    @Test func rowAccessibilityLabelNamesTheAttentionState() {
        #expect(LeoStatusPresentation.rowAccessibilityLabel(row("alpha", attention: .needsInput)) == "alpha, Needs Input")
        #expect(LeoStatusPresentation.rowAccessibilityLabel(row("alpha")) == "alpha, Running")
    }

    // MARK: Row layout

    @Test func attentionRowShowsAnIconOnlyBadgeAndTheStateInTheSubtitle() {
        let presentation = LeoAgentRowPresentation(row: row("alpha", template: "claude", attention: .needsInput), isSelected: false)
        let orange = Color(nsColor: .systemOrange)
        #expect(presentation.badge == .init(symbolName: "questionmark.circle", tint: orange))
        #expect(presentation.subtitle?.text == "claude · Needs Input")
        #expect(presentation.subtitle?.state == .init(label: "Needs Input", tint: orange))
    }

    @Test func selectedAttentionRowUsesThePrimaryColor() {
        let presentation = LeoAgentRowPresentation(row: row("alpha", template: "claude", attention: .errored), isSelected: true)
        #expect(presentation.badge == .init(symbolName: "exclamationmark.triangle", tint: .primary))
        #expect(presentation.subtitle?.state == .init(label: "Errored", tint: .primary))
    }

    @Test func subtitleOmitsWhateverIsMissing() {
        let noTemplate = LeoAgentRowPresentation(row: row("alpha", template: "", attention: .finished), isSelected: false)
        #expect(noTemplate.subtitle?.text == "Finished")
        let noAttention = LeoAgentRowPresentation(row: row("alpha", template: "claude"), isSelected: false)
        #expect(noAttention.badge == nil)
        #expect(noAttention.subtitle?.text == "claude")
        #expect(noAttention.subtitle?.state == nil)
        #expect(LeoAgentRowPresentation(row: row("alpha"), isSelected: false).subtitle == nil)
    }

    // MARK: Jump to Next Needing Attention

    @Test func jumpStartsAfterTheFocusedAgentAndSkipsIt() {
        let order = ids("a", "b", "c", "d")
        let target = LeoAttentionNavigation.next(in: order, needing: Set(ids("a", "b", "d")), focused: id("b"), selected: id("d"))
        #expect(target == id("d"))
    }

    @Test func jumpFallsBackToTheSelectedRowAsTheStart() {
        let order = ids("a", "b", "c", "d")
        #expect(LeoAttentionNavigation.next(in: order, needing: Set(ids("a", "c")), focused: nil, selected: id("c")) == id("a"))
    }

    @Test func jumpWrapsOnceAndSkipsTheFocusedIdentity() {
        let order = ids("a", "b", "c")
        #expect(LeoAttentionNavigation.next(in: order, needing: Set(ids("b")), focused: id("b"), selected: nil) == nil)
        #expect(LeoAttentionNavigation.next(in: order, needing: Set(ids("a")), focused: id("c"), selected: nil) == id("a"))
    }

    @Test func jumpStartsAtTheTopWithoutAnAnchor() {
        let order = ids("a", "b", "c")
        #expect(LeoAttentionNavigation.next(in: order, needing: Set(ids("b", "c")), focused: nil, selected: nil) == id("b"))
        #expect(LeoAttentionNavigation.next(in: order, needing: Set(ids("c")), focused: id("zz"), selected: nil) == id("c"))
    }

    @Test func jumpTargetsTheSelectedRowWhenItIsTheOnlyOneNeedingAttention() {
        let order = ids("a", "b")
        #expect(LeoAttentionNavigation.next(in: order, needing: Set(ids("b")), focused: nil, selected: id("b")) == id("b"))
    }

    @Test func needingAttentionRowsFollowTheirBadges() {
        let rows = [row("a", attention: .working), row("b", attention: .finished), row("c"), row("d", attention: .errored), row("e", attention: .needsInput)]
        #expect(LeoAttentionNavigation.needing(rows) == Set(ids("b", "d", "e")))
    }

    @Test func jumpClearsOnlyAFilterThatHidesTheTarget() {
        let target = row("alpha")
        #expect(LeoAttentionNavigation.filterHides(target, query: "zeta"))
        #expect(!LeoAttentionNavigation.filterHides(target, query: "alp"))
        #expect(!LeoAttentionNavigation.filterHides(target, query: ""))
    }

    @Test func jumpMenuItemNeedsASessionAndATarget() {
        #expect(LeoMenuCommands.canJumpToNextNeedingAttention(hasLeoSession: true, hasTarget: true))
        #expect(!LeoMenuCommands.canJumpToNextNeedingAttention(hasLeoSession: true, hasTarget: false))
        #expect(!LeoMenuCommands.canJumpToNextNeedingAttention(hasLeoSession: false, hasTarget: true))
    }

    // MARK: Dock badge

    @Test func attentionCountTakesPrecedenceOverTheBellCount() {
        #expect(LeoDockBadge.label(attentionCount: 2, bellCount: 5, bellBadgeEnabled: true) == "2")
        #expect(LeoDockBadge.label(attentionCount: 0, bellCount: 5, bellBadgeEnabled: true) == "5")
        #expect(LeoDockBadge.label(attentionCount: 0, bellCount: 5, bellBadgeEnabled: false) == nil)
        #expect(LeoDockBadge.label(attentionCount: 3, bellCount: 0, bellBadgeEnabled: false) == "3")
        #expect(LeoDockBadge.label(attentionCount: 0, bellCount: 0, bellBadgeEnabled: true) == nil)
        #expect(LeoDockBadge.label(attentionCount: 120, bellCount: 0, bellBadgeEnabled: true) == "99+")
    }

    @Test @MainActor func sidebarModelReportsOnlyAttentionCountChanges() {
        let model = LeoSidebarModel()
        var counts: [Int] = []
        model.attentionCountChanged = { counts.append($0) }

        model.receive(.init(rows: [], connectivity: .connected, generation: 1, attentionCount: 2))
        model.receive(.init(rows: [], connectivity: .connected, generation: 2, attentionCount: 2))
        model.receive(.init(rows: [], connectivity: .connected, generation: 3, attentionCount: 0))

        #expect(counts == [2, 0])
    }

    private func id(_ name: String) -> LeoAgentRow.ID { .init(host: Self.host, name: name) }
    private func ids(_ names: String...) -> [LeoAgentRow.ID] { names.map(id) }
    private func row(_ name: String, template: String? = nil, attention: LeoAttentionBadge? = nil) -> LeoAgentRow {
        LeoAgentRow(host: Self.host, name: name, template: template, status: .running, activity: .idle, actionDetail: nil, attention: attention)
    }
}
