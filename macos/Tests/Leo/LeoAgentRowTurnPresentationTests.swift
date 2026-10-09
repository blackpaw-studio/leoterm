import Foundation
import Testing

@testable import Ghostty

/// B-259: how a row writes an agent's usage and last turn.
struct LeoAgentRowTurnPresentationTests {
    @Test func tokensAreCompact() {
        #expect(LeoUsageFormat.tokens(0) == "0")
        #expect(LeoUsageFormat.tokens(999) == "999")
        #expect(LeoUsageFormat.tokens(1000) == "1k")
        #expect(LeoUsageFormat.tokens(12_345) == "12.3k")
        #expect(LeoUsageFormat.tokens(999_949) == "999.9k")
        #expect(LeoUsageFormat.tokens(999_950) == "1M")
        #expect(LeoUsageFormat.tokens(1_234_567) == "1.2M")
    }

    @Test func costIsDollarsWithASubCentFloor() {
        #expect(LeoUsageFormat.cost(0) == "$0.00")
        #expect(LeoUsageFormat.cost(0.004) == "<$0.01")
        #expect(LeoUsageFormat.cost(0.42) == "$0.42")
        #expect(LeoUsageFormat.cost(12.345) == "$12.35" || LeoUsageFormat.cost(12.345) == "$12.34")
    }

    @Test func summaryRoundsContextAndOmitsItWhenAbsent() {
        let withContext = LeoAgentUsage(
            session: LeoUsageTotals(tokens: 12_345, costUSD: 0.42), context: LeoContextUsage(tokens: 1, window: 2, percent: 36.6)
        )
        #expect(LeoUsageFormat.summary(withContext) == "12.3k tok · $0.42 · 37% ctx")
        let bare = LeoAgentUsage(session: LeoUsageTotals(tokens: 0, costUSD: 0))
        #expect(LeoUsageFormat.summary(bare) == "0 tok · $0.00")
        #expect(!LeoUsageFormat.summary(bare).contains("ctx"))
    }

    @Test func tooltipHasTheWholeNumbers() {
        let usage = LeoAgentUsage(
            session: LeoUsageTotals(tokens: 12_345, costUSD: 0.42), incarnation: LeoUsageTotals(tokens: 50_000, costUSD: 1.5),
            context: LeoContextUsage(tokens: 74_000, window: 200_000, percent: 37)
        )
        #expect(LeoUsageFormat.tooltip(usage) == "Session: 12,345 tokens, $0.42\nSince start: 50,000 tokens, $1.50\nContext: 74,000 of 200,000 tokens (37%)")
    }

    @Test func usageIsASubtitleSegmentThatGivesWayFirst() throws {
        let usage = LeoAgentUsage(session: LeoUsageTotals(tokens: 12_345, costUSD: 0.42))
        let presentation = LeoAgentRowPresentation(row: row(metadata: metadata(usage: usage)), isSelected: false)
        let subtitle = try #require(presentation.subtitle)
        #expect(subtitle.segments.map(\.text) == ["claude", "12.3k tok · $0.42"])
        #expect(subtitle.segments.last?.truncation == .usage)
        #expect(LeoAgentRowPresentation.Subtitle.Truncation.usage.layoutPriority < LeoAgentRowPresentation.Subtitle.Truncation.first.layoutPriority)
        #expect(subtitle.help.contains("Session: 12,345 tokens"))
        #expect(subtitle.accessibilityLabel.contains("used 12,345 tokens"))
    }

    @Test func emptyUsageAddsNothing() {
        let usage = LeoAgentUsage(session: LeoUsageTotals(tokens: 0, costUSD: 0))
        let presentation = LeoAgentRowPresentation(row: row(template: nil, metadata: metadata(usage: usage)), isSelected: false)
        #expect(presentation.subtitle == nil)
    }

    @Test func previewShowsOnlyWithoutATask() {
        let turn = LeoTurnPreview(text: "Fixed the bug", outcome: .completed)
        #expect(LeoAgentRowPresentation(row: row(lastTurn: turn), isSelected: false).turnPreview == LeoSFTPServerText.isolated("Fixed the bug"))
        let busy = row(metadata: LeoAgentMetadata(lastActiveAt: nil, isWorking: true, task: "Reading files"), lastTurn: turn)
        #expect(LeoAgentRowPresentation(row: busy, isSelected: false).turnPreview == nil, "the task line wins")
        #expect(LeoAgentRowPresentation(row: row(), isSelected: false).turnPreview == nil)
    }

    @Test func aRunningToolHidesThePreviewAndIsSpoken() {
        let turn = LeoTurnPreview(text: "Fixed the bug", outcome: .completed)
        let running = row(metadata: LeoAgentMetadata(lastActiveAt: nil, isWorking: true, task: nil, tool: "Bash"), lastTurn: turn)
        let presentation = LeoAgentRowPresentation(row: running, isSelected: false)
        #expect(presentation.tool == "Bash")
        let runningBash = "Running " + LeoSFTPServerText.isolated("Bash")
        #expect(presentation.toolSpoken == runningBash)
        #expect(presentation.toolHelp == runningBash)
        #expect(presentation.task == nil)
        #expect(presentation.turnPreview == nil, "the tool wins over the preview")
        let idle = LeoAgentRowPresentation(row: row(lastTurn: turn), isSelected: false)
        #expect(idle.tool == nil)
        #expect(idle.toolSpoken == nil && idle.toolHelp == nil)
        #expect(idle.turnPreview != nil, "the preview returns once the tool is gone")
    }

    @Test func anAbortedTurnIsLabelled() {
        let aborted = row(lastTurn: LeoTurnPreview(text: "Half done", outcome: .aborted))
        #expect(LeoAgentRowPresentation(row: aborted, isSelected: false).turnPreview == "Interrupted: " + LeoSFTPServerText.isolated("Half done"))
    }

    @Test func recordedPreviewIsSanitizedAndClamped() throws {
        let long = String(repeating: "word ", count: 200)
        let json = #"{"seq":1,"agent":"alpha","outcome":"completed","preview":"line one\nline \u0000two \#(long)"}"#
        guard case .agentTurnCompleted(_, let turn) = LeoActivityClient.decode(LeoSSEEvent(name: "agent_turn_completed", data: json, id: nil)) else {
            Issue.record("not a turn")
            return
        }
        #expect(!turn.preview.contains("\n"))
        #expect(turn.preview.count <= LeoSFTPServerText.limit)
        #expect(turn.preview.hasPrefix("line one line"))
    }

    @Test func previewsAttachOnlyToTheirOwnIncarnation() {
        let completion = LeoTurnCompletion(agent: "alpha", outcome: .completed, preview: "Done")
        let previews = LeoTurnPreviews.empty.recording(completion, startedAt: "t1")
        #expect(previews.preview(name: "alpha", startedAt: "t1")?.text == "Done")
        #expect(previews.preview(name: "alpha", startedAt: "t2") == nil, "a recreated namesake")
        #expect(previews.preview(name: "alpha", startedAt: nil) == nil)
        let cleared = previews.recording(LeoTurnCompletion(agent: "alpha", outcome: .completed, preview: ""), startedAt: "t1")
        #expect(cleared.preview(name: "alpha", startedAt: "t1") == nil, "an empty preview clears the line")
    }

    /// A row's height must not depend on tool, task, or preview state: the
    /// third line is always a slot, `.empty` when nothing fills it.
    @Test func thirdLineSlotIsAlwaysPresentAndTracksTheToolOnAndOff() {
        let quiet = LeoAgentRowPresentation(row: row(), isSelected: false)
        #expect(quiet.detail == .empty, "no task, tool, preview or compaction still reserves the slot")
        let running = row(metadata: LeoAgentMetadata(lastActiveAt: nil, isWorking: true, task: nil, tool: "Bash"))
        #expect(LeoAgentRowPresentation(row: running, isSelected: false).detail == .tool("Bash"))
        #expect(LeoAgentRowPresentation(row: row(metadata: LeoAgentMetadata(lastActiveAt: nil, isWorking: false, task: nil)), isSelected: false).detail == .empty, "the slot remains once the tool is gone")
    }

    @Test func thirdLineSlotKeepsTheVariantOrder() {
        let turn = LeoTurnPreview(text: "Done", outcome: .completed)
        let all = row(metadata: LeoAgentMetadata(lastActiveAt: nil, isWorking: true, task: "Reading", tool: "Bash"), lastTurn: turn)
        #expect(LeoAgentRowPresentation(row: all, isSelected: false).detail == .task("Reading"))
        let previewOnly = LeoAgentRowPresentation(row: row(lastTurn: turn), isSelected: false)
        #expect(previewOnly.detail == .turnPreview(LeoSFTPServerText.isolated("Done")))
    }

    private func metadata(usage: LeoAgentUsage) -> LeoAgentMetadata {
        LeoAgentMetadata(lastActiveAt: nil, isWorking: false, task: nil, usage: usage)
    }

    private func row(template: String? = "claude", metadata: LeoAgentMetadata? = nil, lastTurn: LeoTurnPreview? = nil) -> LeoAgentRow {
        LeoAgentRow(
            host: .local, name: "alpha", template: template, status: .running, activity: .idle, actionDetail: nil,
            startedAt: "t1", metadata: metadata, lastTurn: lastTurn
        )
    }
}
