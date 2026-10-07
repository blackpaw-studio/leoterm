import Testing

@testable import Ghostty

/// B-261: how a compacting row writes itself.
struct LeoAgentRowCompactionPresentationTests {
    private func row(compaction: LeoRowCompaction?, attention: LeoAttentionBadge? = nil) -> LeoAgentRow {
        LeoAgentRow(
            host: .local, name: "alpha", template: "claude", status: .running, activity: .working, actionDetail: nil,
            attention: attention, startedAt: "t1",
            metadata: LeoAgentMetadata(lastActiveAt: nil, isWorking: true, task: "Reading files", tool: "Bash"),
            lastTurn: LeoTurnPreview(text: "Fixed the bug", outcome: .completed), compaction: compaction
        )
    }

    @Test func compactingReplacesToolTaskAndPreview() {
        let presentation = LeoAgentRowPresentation(row: row(compaction: LeoRowCompaction(trigger: .auto)), isSelected: false)
        #expect(presentation.compacting == "Compacting context")
        #expect(presentation.task == nil && presentation.tool == nil && presentation.turnPreview == nil)
        #expect(presentation.badge == nil, "compacting earns no badge")
    }

    @Test func notCompactingLeavesTheOtherLines() {
        let presentation = LeoAgentRowPresentation(row: row(compaction: nil), isSelected: false)
        #expect(presentation.compacting == nil && presentation.compactingHelp == nil)
        #expect(presentation.task == "Reading files" && presentation.tool == "Bash")
    }

    @Test func compactingHelpNamesTheTrigger() {
        func help(_ trigger: LeoCompactionTrigger?) -> String? {
            LeoAgentRowPresentation(row: row(compaction: LeoRowCompaction(trigger: trigger)), isSelected: false).compactingHelp
        }
        #expect(help(.auto) == "Compacting context (automatic)")
        #expect(help(.manual) == "Compacting context (requested)")
        #expect(help(nil) == "Compacting context")
    }

    @Test func compactingKeepsTheAttentionBadge() {
        let presentation = LeoAgentRowPresentation(row: row(compaction: LeoRowCompaction(trigger: nil), attention: .needsInput), isSelected: false)
        #expect(presentation.badge != nil, "a state the daemon reported is never hidden")
    }
}
