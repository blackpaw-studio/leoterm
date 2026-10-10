import SwiftUI
import Testing

@testable import Ghostty

/// Attention reasons, VoiceOver text, Jump to Next Needing Attention and the Dock
/// label -- the pure decisions behind the attention UI.
struct LeoAttentionPresentationTests {
    private static let host = LeoHostID.local

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
        let rowPresentation = LeoAgentRowPresentation(row: needsPermission, error: nil)
        #expect(rowPresentation.accessibilityLabel(name: "alpha") == "alpha, Needs Permission, Bash")
        #expect(rowPresentation.pill.symbolName == "hand.raised")
        #expect(rowPresentation.pill.help == "Needs permission to use Bash: rm")
        #expect(rowPresentation.detail == .attention("Bash: rm"))
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
        let presentation = LeoAgentRowPresentation(row: plain, error: nil)
        #expect(presentation.pill.symbolName == "questionmark.circle")
        #expect(presentation.pill.help == nil)
        #expect(presentation.detail == .fallback("claude"))
    }

    @Test func reasonIsIgnoredUnlessTheBadgeIsNeedsInput() {
        let stray = row("alpha", attention: .finished, reason: LeoAttentionReason(kind: .question))
        let presentation = LeoAgentRowPresentation(row: stray, error: nil)
        #expect(presentation.pill.symbolName == "checkmark")
        #expect(presentation.accessibilityLabel(name: "alpha") == "alpha, Done")
    }

    @Test func withMetadataAndSurfacedFilesKeepTheReason() {
        let reasoned = row("alpha", attention: .needsInput, reason: LeoAttentionReason(kind: .question))
        #expect(reasoned.withMetadata(nil).attentionReason?.kind == .question)
        #expect(reasoned.withSurfacedFiles([]).attentionReason?.kind == .question)
        #expect(reasoned.withAttention(.needsInput).attentionReason == nil)
    }
}
