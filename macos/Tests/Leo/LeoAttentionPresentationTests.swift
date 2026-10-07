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
    private func row(
        _ name: String, template: String? = nil, attention: LeoAttentionBadge? = nil, reason: LeoAttentionReason? = nil
    ) -> LeoAgentRow {
        LeoAgentRow(
            host: Self.host, name: name, template: template, status: .running, activity: .idle, actionDetail: nil,
            attention: attention, attentionReason: reason
        )
    }

    // MARK: attention.reason (B-258)

    @Test func permissionReasonPresentation() {
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash", detail: "rm")
        let presentation = LeoStatusPresentation.attentionReason(reason)
        #expect(presentation.symbolName == "hand.raised")
        #expect(presentation.stateWord == "Permission: Bash")
        #expect(presentation.tooltip == "Needs permission to use Bash: rm")
        #expect(presentation.notificationBody == "Needs permission to use Bash")
        let needsPermission = row("alpha", template: "claude", attention: .needsInput, reason: reason)
        #expect(LeoStatusPresentation.rowAccessibilityLabel(needsPermission) == "alpha, Needs Permission, Bash")
        let rowPresentation = LeoAgentRowPresentation(row: needsPermission, isSelected: false)
        #expect(rowPresentation.badge?.symbolName == "hand.raised")
        #expect(rowPresentation.badge?.tooltip == "Needs permission to use Bash: rm")
        #expect(rowPresentation.subtitle?.text == "claude · Permission: Bash")
    }

    @Test func questionReasonPresentation() {
        let presentation = LeoStatusPresentation.attentionReason(LeoAttentionReason(kind: .question))
        #expect(presentation.symbolName == "questionmark.bubble")
        #expect(presentation.stateWord == "Question")
        #expect(presentation.tooltip == "Asking you a question")
        #expect(presentation.notificationBody == "Has a question for you")
    }

    @Test func elicitationReasonPresentation() {
        let bare = LeoStatusPresentation.attentionReason(LeoAttentionReason(kind: .elicitation))
        #expect(bare.symbolName == "list.bullet.rectangle")
        #expect(bare.stateWord == "Input Request")
        #expect(bare.tooltip == "Requesting input")
        let tooled = LeoStatusPresentation.attentionReason(LeoAttentionReason(kind: .elicitation, tool: "github"))
        #expect(tooled.tooltip == "Requesting input from github")
        #expect(tooled.notificationBody == "Requesting input")
    }

    @Test func noReasonPresentationUnchanged() {
        let plain = row("alpha", template: "claude", attention: .needsInput)
        let presentation = LeoAgentRowPresentation(row: plain, isSelected: false)
        #expect(presentation.badge?.symbolName == "questionmark.circle")
        #expect(presentation.badge?.tooltip == nil)
        #expect(presentation.subtitle?.text == "claude · Needs Input")
    }

    @Test func reasonIsIgnoredUnlessTheBadgeIsNeedsInput() {
        let stray = row("alpha", attention: .finished, reason: LeoAttentionReason(kind: .question))
        #expect(LeoAgentRowPresentation(row: stray, isSelected: false).badge?.symbolName == "checkmark.circle")
        #expect(LeoStatusPresentation.rowAccessibilityLabel(stray) == "alpha, Finished")
    }

    @Test func withMetadataAndSurfacedFilesKeepTheReason() {
        let reasoned = row("alpha", attention: .needsInput, reason: LeoAttentionReason(kind: .question))
        #expect(reasoned.withMetadata(nil).attentionReason?.kind == .question)
        #expect(reasoned.withSurfacedFiles([]).attentionReason?.kind == .question)
        #expect(reasoned.withAttention(.needsInput).attentionReason == nil)
    }
}
