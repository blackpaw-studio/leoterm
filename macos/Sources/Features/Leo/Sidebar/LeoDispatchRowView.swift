import SwiftUI

/// What a nested dispatch row shows (B-257): its name (else its role), and
/// its status word as secondary text. Informational only: no badge, no
/// motion, no selection -- only "needs you" earns attention (principle 2).
struct LeoDispatchRowPresentation: Equatable {
    /// Leading inset of a depth-0 child, inside its agent row.
    static let baseIndent: CGFloat = 12
    static let indentPerLevel: CGFloat = 12
    /// Deeper levels share the last indent, so the name keeps its room.
    static let maxIndentDepth = 4

    let title: String
    let statusText: String
    let indent: CGFloat
    let accessibilityLabel: String

    init(_ node: LeoDispatchNode) {
        let dispatch = node.dispatch
        title = dispatch.name ?? dispatch.role ?? "Dispatch"
        let status = Self.statusWord(dispatch.status)
        statusText = dispatch.stalled ? "\(status) · Stalled" : status
        indent = Self.baseIndent + CGFloat(min(node.depth, Self.maxIndentDepth)) * Self.indentPerLevel
        accessibilityLabel = "\(title), \(node.depth == 0 ? "dispatch" : "nested dispatch"), \(statusText)"
    }

    /// "queued" → "Queued"; an unknown status still reads ("brand_new" →
    /// "Brand new").
    private static func statusWord(_ status: String) -> String {
        let words = status.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// One live dispatch under its agent row: indented by depth, never
/// selectable (no tag), dimmed and inert with its agent rows when
/// disconnected.
struct LeoDispatchRowView: View {
    let node: LeoDispatchNode

    var body: some View {
        let presentation = LeoDispatchRowPresentation(node)
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(presentation.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(presentation.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, presentation.indent)
        .help(presentation.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .leoSelectionDisabled()
    }
}

private extension View {
    /// Keeps arrow keys and clicks off the row where the OS supports it;
    /// on macOS 13 the missing tag alone keeps it unselectable.
    @ViewBuilder func leoSelectionDisabled() -> some View {
        if #available(macOS 14, *) {
            selectionDisabled()
        } else {
            self
        }
    }
}
