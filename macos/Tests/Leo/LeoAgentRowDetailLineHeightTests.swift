import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// A row's height must not depend on which detail variant it shows: the
/// SF Symbols in the tool and compaction labels once made them taller.
@MainActor
struct LeoAgentRowDetailLineHeightTests {
    private static let tolerance: CGFloat = 0.5

    @Test func everyDetailVariantRendersAtTheSameHeightAsTheEmptySlot() {
        let turn = LeoTurnPreview(text: "Fixed the bug", outcome: .completed)
        let variants: [(String, LeoAgentRow)] = [
            ("empty", row()),
            ("task", row(metadata: LeoAgentMetadata(lastActiveAt: nil, isWorking: true, task: "Reading files"))),
            ("tool", row(metadata: LeoAgentMetadata(lastActiveAt: nil, isWorking: true, task: nil, tool: "Bash"))),
            ("preview", row(lastTurn: turn)),
            ("compacting", row(compaction: LeoRowCompaction(trigger: .auto)))
        ]
        let heights = variants.map { name, row in
            (name, height(of: LeoAgentRowPresentation(row: row, isSelected: false)))
        }
        let empty = heights[0].1
        #expect(empty > 0)
        for (name, height) in heights {
            #expect(abs(height - empty) <= Self.tolerance, "\(name) is \(height)pt, empty is \(empty)pt")
        }
    }

    private func height(of presentation: LeoAgentRowPresentation) -> CGFloat {
        NSHostingView(rootView: LeoAgentRowDetailLine(details: presentation).frame(width: 200)).fittingSize.height
    }

    private func row(
        metadata: LeoAgentMetadata? = nil, lastTurn: LeoTurnPreview? = nil, compaction: LeoRowCompaction? = nil
    ) -> LeoAgentRow {
        LeoAgentRow(
            host: .local, name: "alpha", template: "claude", status: .running, activity: .idle, actionDetail: nil,
            startedAt: "t1", metadata: metadata, lastTurn: lastTurn, compaction: compaction
        )
    }
}
