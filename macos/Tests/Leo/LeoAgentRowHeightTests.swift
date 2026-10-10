import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// A row's height must not depend on its pill state, which detail it shows,
/// a pending action, selection, or what the name line carries: a tool
/// starting or an agent finishing must not move the rows below it.
@MainActor
struct LeoAgentRowHeightTests {
    private static let width: CGFloat = 200
    private static let tolerance: CGFloat = 0.5
    private let turn = LeoTurnPreview(text: "Fixed the bug", outcome: .completed)
    private let reason = LeoAttentionReason(kind: .permission, tool: "Bash", detail: "rm -rf build")
    private let usage = LeoAgentUsage(session: LeoUsageTotals(tokens: 12_345, costUSD: 0.42))

    private func variants() -> [(String, LeoAgentRow, String?)] {
        func busy(task: String? = nil, tool: String? = nil, working: Bool = false) -> LeoAgentMetadata {
            LeoAgentMetadata(lastActiveAt: Date(), isWorking: working, task: task, usage: usage, tool: tool)
        }
        func row(
            _ status: LeoAgentStatus = .running, activity: LeoAgentRow.Activity = .idle, attention: LeoAttentionBadge? = nil,
            reason: LeoAttentionReason? = nil, metadata: LeoAgentMetadata? = nil, lastTurn: LeoTurnPreview? = nil,
            compaction: LeoRowCompaction? = nil, template: String? = "claude"
        ) -> LeoAgentRow {
            LeoAgentRow(
                host: .local, name: "alpha", template: template, status: status, activity: activity, actionDetail: nil,
                attention: attention, attentionReason: reason, metadata: metadata, lastTurn: lastTurn, compaction: compaction
            )
        }
        return [
            // Every pill state.
            ("needsYou+reason", row(attention: .needsInput, reason: reason), nil),
            ("needsYou", row(attention: .needsInput), nil),
            ("error attention", row(attention: .errored), nil),
            ("error text", row(), "Start failed: no such template"),
            ("done", row(attention: .finished), nil),
            ("starting", row(.starting), nil),
            ("stopped", row(.stopped), nil),
            ("unknown", row(.unknown("weird")), nil),
            ("compacting", row(compaction: LeoRowCompaction(trigger: .auto)), nil),
            ("working", row(activity: .working, metadata: busy(working: true)), nil),
            ("idle", row(), nil),
            // Every detail variant.
            ("task", row(metadata: busy(task: "Reading files")), nil),
            ("tool", row(metadata: busy(tool: "Bash")), nil),
            ("preview", row(lastTurn: turn), nil),
            ("fallback bare", row(template: nil), nil),
            ("long task", row(metadata: busy(task: String(repeating: "Reading a very long file name ", count: 6))), nil)
        ]
    }

    @Test func everyPillStateAndDetailVariantRendersAtTheSameHeight() {
        let all = variants().map { name, row, error in (name, height(row: row, error: error)) }
        let baseline = all[0].1
        let expected = 2 * LeoAgentRowMetrics.verticalPadding + LeoAgentRowMetrics.nameLineHeight
            + LeoAgentRowMetrics.lineSpacing + LeoAgentRowMetrics.detailLineHeight
        #expect(abs(baseline - expected) <= Self.tolerance, "row is \(baseline)pt, its pinned lines add up to \(expected)pt")
        for (name, height) in all {
            #expect(abs(height - baseline) <= Self.tolerance, "\(name) is \(height)pt, baseline is \(baseline)pt")
        }
    }

    @Test func selectionAndPendingActionsDoNotChangeTheHeight() {
        let (_, row, _) = variants()[0]
        let baseline = height(row: row, error: nil)
        let selected = height(row: row, error: nil, isSelected: true)
        let pending = height(row: row, error: nil, isPending: true)
        let files = height(row: row, error: nil, files: [LeoSurfacedFile(id: "f1", agent: "alpha", startedAt: "t1", path: "a.md", absPath: "/a.md")])
        #expect(abs(selected - baseline) <= Self.tolerance, "selected is \(selected)pt, baseline is \(baseline)pt")
        #expect(abs(pending - baseline) <= Self.tolerance, "pending is \(pending)pt, baseline is \(baseline)pt")
        #expect(abs(files - baseline) <= Self.tolerance, "surfaced files is \(files)pt, baseline is \(baseline)pt")
    }

    private func height(
        row: LeoAgentRow, error: String?, isSelected: Bool = false, isPending: Bool = false, files: [LeoSurfacedFile] = []
    ) -> CGFloat {
        let content = LeoAgentRowContent(
            row: row, error: error, isSelected: isSelected, isPending: isPending, nameHighlights: [], pendingSurfacedFiles: files
        )
        return NSHostingView(rootView: content.frame(width: Self.width)).fittingSize.height
    }
}
