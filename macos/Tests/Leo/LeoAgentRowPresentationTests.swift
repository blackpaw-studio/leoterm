import Foundation
import Testing

@testable import Ghostty

/// Line 2 of an agent row: the detail precedence, its fallback, and the
/// tooltip / time that ride beside it.
struct LeoAgentRowPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let locale = Locale(identifier: "en_US")

    private func presentation(
        template: String? = "claude", attention: LeoAttentionBadge? = nil, reason: LeoAttentionReason? = nil,
        metadata: LeoAgentMetadata? = nil, lastTurn: LeoTurnPreview? = nil, compaction: LeoRowCompaction? = nil,
        status: LeoAgentStatus = .running, error: String? = nil, now: Date? = nil, inWorkingSection: Bool = false
    ) -> LeoAgentRowPresentation {
        let row = LeoAgentRow(
            host: .local, name: "alpha", template: template, status: status, activity: .idle, actionDetail: nil,
            attention: attention, attentionReason: reason, metadata: metadata, lastTurn: lastTurn, compaction: compaction
        )
        return LeoAgentRowPresentation(
            row: row, error: error, now: now, timeZone: TimeZone(identifier: "UTC")!, locale: Self.locale,
            inWorkingSection: inWorkingSection
        )
    }

    private func metadata(task: String? = nil, tool: String? = nil, usage: LeoAgentUsage? = nil, lastActiveAt: Date? = nil, isWorking: Bool = false) -> LeoAgentMetadata {
        LeoAgentMetadata(lastActiveAt: lastActiveAt, isWorking: isWorking, task: task, usage: usage, tool: tool)
    }

    private let turn = LeoTurnPreview(text: "Fixed the bug", outcome: .completed)

    // MARK: Precedence

    @Test func attentionReasonLeadsAsToolAndDetail() {
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash", detail: "rm -rf build")
        let everything = presentation(
            attention: .needsInput, reason: reason, metadata: metadata(task: "Reading", tool: "Edit"), lastTurn: turn, error: "boom"
        )
        #expect(everything.detail == .attention("Bash: rm -rf build"))
        #expect(presentation(attention: .needsInput, reason: LeoAttentionReason(kind: .permission, tool: "Bash")).detail == .attention("Bash"))
        #expect(presentation(attention: .needsInput, reason: LeoAttentionReason(kind: .question, detail: "Which branch?")).detail == .attention("Which branch?"))
    }

    @Test func aReasonOnlyCountsWhileTheAgentNeedsInput() {
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash")
        #expect(presentation(attention: .working, reason: reason, metadata: metadata(task: "Reading")).detail == .task("Reading"))
    }

    @Test func errorTextBeatsTaskToolAndPreview() {
        let busy = metadata(task: "Reading", tool: "Edit")
        #expect(presentation(metadata: busy, lastTurn: turn, error: "Start failed").detail == .error("Start failed"))
        #expect(presentation(metadata: busy, error: "").detail == .task("Reading"))
    }

    @Test func taskThenToolThenTurnPreview() {
        #expect(presentation(metadata: metadata(task: "Reading", tool: "Edit"), lastTurn: turn).detail == .task("Reading"))
        #expect(presentation(metadata: metadata(tool: "Edit"), lastTurn: turn).detail == .tool("Edit"))
        #expect(presentation(lastTurn: turn).detail == .turnPreview(LeoSFTPServerText.isolated("Fixed the bug")))
    }

    @Test func anAbortedTurnIsLabelled() {
        let aborted = LeoTurnPreview(text: "Half done", outcome: .aborted)
        #expect(presentation(lastTurn: aborted).detail == .turnPreview("Interrupted: " + LeoSFTPServerText.isolated("Half done")))
    }

    @Test func compactionLeavesTheDetailChain() {
        let compacting = presentation(metadata: metadata(task: "Reading"), compaction: LeoRowCompaction(trigger: .manual))
        #expect(compacting.detail == .task("Reading"))
        #expect(presentation(compaction: LeoRowCompaction(trigger: .manual)).detail == .fallback("claude"))
    }

    // MARK: Fallback

    @Test func fallbackIsTemplateAndSessionCost() {
        let usage = LeoAgentUsage(session: LeoUsageTotals(tokens: 12_345, costUSD: 0.42))
        #expect(presentation(metadata: metadata(usage: usage)).detail == .fallback("claude · $0.42"))
        #expect(presentation().detail == .fallback("claude"))
    }

    @Test func fallbackDropsMissingPartsButIsNeverBlank() {
        let usage = LeoAgentUsage(session: LeoUsageTotals(tokens: 5, costUSD: 1.5))
        #expect(presentation(template: nil, metadata: metadata(usage: usage)).detail == .fallback("$1.50"))
        #expect(presentation(template: "").detail == .fallback(LeoAgentRowPresentation.emptyFallback))
        let zero = LeoAgentUsage(session: LeoUsageTotals(tokens: 0, costUSD: 0))
        #expect(presentation(template: nil, metadata: metadata(usage: zero)).detail == .fallback(LeoAgentRowPresentation.emptyFallback))
    }

    @Test func detailTextIsTheStringTheLineDraws() {
        #expect(presentation(metadata: metadata(task: "Reading")).detail.text == "Reading")
        #expect(presentation(error: "Start failed").detail.text == "Start failed")
        #expect(presentation().detail.text == "claude")
    }

    // MARK: Time, tooltip, name

    @Test func trailingTimeIsTheRelativeLastActive() {
        let active = metadata(lastActiveAt: Self.now.addingTimeInterval(-300))
        let resolved = presentation(metadata: active, now: Self.now)
        #expect(resolved.lastActive == "5m")
        #expect(resolved.lastActiveSpoken == "last active 5 minutes ago")
        #expect(presentation(metadata: active).lastActive == nil, "no clock, no time")
        #expect(presentation(now: Self.now).lastActive == nil, "no metadata, no time")
    }

    @Test func aWorkingAgentIsActiveNow() {
        let working = metadata(lastActiveAt: Self.now.addingTimeInterval(-3600), isWorking: true)
        #expect(presentation(metadata: working, now: Self.now).lastActive == "now")
    }

    @Test func rowHelpHoldsTemplateAndUsage() {
        let usage = LeoAgentUsage(session: LeoUsageTotals(tokens: 12_345, costUSD: 0.42))
        #expect(presentation(metadata: metadata(usage: usage)).help == "claude\nSession: 12,345 tokens, $0.42")
        #expect(presentation().help == "claude")
        #expect(presentation(template: nil).help == "")
    }

    @Test func stoppedRowsDimTheirName() {
        #expect(presentation(status: .stopped).isNameDimmed)
        #expect(!presentation(status: .running).isNameDimmed)
    }

    @Test func onlyThePlaceholderFallbackIsTertiary() {
        let usage = LeoAgentUsage(session: LeoUsageTotals(tokens: 5, costUSD: 0.42))
        let withCost = presentation(attention: .finished, metadata: metadata(usage: usage))
        #expect(withCost.detail == .fallback("claude · $0.42"))
        #expect(withCost.detailInk == .secondary)
        #expect(presentation(attention: .working).detailInk == .secondary)
        let placeholder = presentation(template: nil, attention: .finished)
        #expect(placeholder.detail == .fallback(LeoAgentRowPresentation.emptyFallback))
        #expect(placeholder.detailInk == .tertiary)
        #expect(presentation(template: nil, attention: .needsInput).detailInk == .tint(.orange))
    }

    @Test func theWorkingSectionFlagReachesTheState() {
        let working = presentation(attention: .working, inWorkingSection: true)
        #expect(!working.state.hasSecondLine)
        #expect(working.state.trailingWord == "Working")
        #expect(presentation(attention: .working).state.hasSecondLine)
    }

    @Test func nameLabelCarriesTheStateForVoiceOver() {
        #expect(presentation(attention: .needsInput).accessibilityLabel(name: "alpha") == "alpha, Needs you")
        #expect(presentation().accessibilityLabel(name: "alpha") == "alpha, Idle")
    }
}
