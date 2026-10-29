import SwiftUI
import LeoKit

/// An agent row: a leading state symbol, then the name line (the emoji, the
/// name and the last-active time, a state word, or a spinner while an action
/// is pending) and, for states that have one, a detail line aligned with the
/// name, then the agent's color bar (or a blank slot of the same width) on
/// the trailing edge. Each line is pinned to a fixed height and whether there is a
/// second line is fixed per state, so the row never resizes as its content
/// changes.
struct LeoAgentRowContent: View {
    let row: LeoAgentRow
    let error: String?
    let isSelected: Bool
    let isPending: Bool
    /// Name characters the search query matched, drawn bold.
    let nameHighlights: [Int]
    /// Whether the row sits in the Working section (grouped by attention):
    /// one line, with the word trailing.
    var inWorkingSection = false
    /// Unread chat messages from the agent, as a capsule at the end of the
    /// name line. Independent of the leading attention symbol.
    var unreadCount = 0
    /// B-331: set only for a row with dispatches.
    var subagents: Subagents?

    /// The row's dispatch rows are collapsed or shown: a chevron (outside
    /// the row's click area) and, while collapsed, how many are running.
    struct Subagents {
        let isCollapsed: Bool
        let runningCount: Int
        let toggle: () -> Void
    }

    var body: some View {
        let presentation = LeoAgentRowPresentation(row: row, error: error, inWorkingSection: inWorkingSection)
        HStack(alignment: .top, spacing: LeoAgentRowMetrics.symbolSpacing) {
            LeoAgentStateSymbolView(state: presentation.state, isSelected: isSelected)
            VStack(alignment: .leading, spacing: LeoAgentRowMetrics.lineSpacing) {
                nameLine(presentation)
                if presentation.state.hasSecondLine { detailLine(presentation) }
            }
        }
        // The bar spans the row's lines without adding to its height.
        .padding(.trailing, LeoAgentRowMetrics.colorBarSlot)
        .background(alignment: .trailing) { colorBar(presentation.barColor) }
        .padding(.vertical, LeoAgentRowMetrics.verticalPadding)
        .help(presentation.help)
    }

    private func nameLine(_ presentation: LeoAgentRowPresentation) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: LeoAgentRowMetrics.emojiSpacing) {
                if let emoji = presentation.leadingEmoji {
                    // Its own Text, so name highlights still index the name.
                    Text(emoji)
                        .font(.callout)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                nameText
                    .fontWeight(.medium)
                    .foregroundStyle(presentation.isNameDimmed ? .secondary : .primary)
                    .lineLimit(1)
                    .accessibilityLabel(presentation.accessibilityLabel(name: row.name))
            }
            Spacer(minLength: 4)
            LeoAgentBrowserBadge(host: row.host, agent: row.name, isSelected: isSelected)
            trailing(presentation.state)
            LeoUnreadCountBadge(count: unreadCount, isOnSelection: isSelected)
            if let subagents { subagentsControls(subagents) }
        }
        .frame(height: LeoAgentRowMetrics.nameLineHeight)
    }

    @ViewBuilder private func subagentsControls(_ subagents: Subagents) -> some View {
        if subagents.isCollapsed { LeoRunningSubagentsBadge(count: subagents.runningCount, isOnSelection: isSelected) }
        Button(action: subagents.toggle) {
            Image(systemName: subagents.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: LeoAgentRowMetrics.disclosureSize, height: LeoAgentRowMetrics.disclosureSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subagents.isCollapsed ? "Show subagents" : "Hide subagents")
        .help(subagents.isCollapsed ? "Show subagents" : "Hide subagents")
        .leoSelectionDisabled()
    }

    @ViewBuilder private func colorBar(_ color: LeoAppearanceColor?) -> some View {
        if let color {
            RoundedRectangle(cornerRadius: LeoAgentRowMetrics.colorBarWidth / 2)
                .fill(color.swiftUIColor)
                .frame(width: LeoAgentRowMetrics.colorBarWidth)
                .accessibilityHidden(true)
        }
    }

    private var nameText: Text {
        LeoFuzzyMatcher.highlightRuns(name: row.name, offsets: nameHighlights).reduce(Text("")) { text, run in
            text + Text(run.text).fontWeight(run.isMatched ? .bold : nil)
        }
    }

    /// A pending action replaces the time; a state word (Compacting) does
    /// too. Only a row with a "last active" time re-renders it, once a
    /// minute -- never per event.
    @ViewBuilder private func trailing(_ state: LeoAgentRowState) -> some View {
        if isPending {
            ProgressView().controlSize(.small)
        } else if let word = state.trailingWord, let ink = state.trailingInk {
            Text(word)
                .font(.caption)
                .foregroundStyle(ink.style(isSelected: isSelected))
                .lineLimit(1)
                .fixedSize()
        } else if row.metadata?.lastActiveAt != nil || row.metadata?.isWorking == true {
            TimelineView(.everyMinute) { context in
                timeText(LeoAgentRowPresentation(row: row, error: error, now: context.date, inWorkingSection: inWorkingSection))
            }
        }
    }

    @ViewBuilder private func timeText(_ presentation: LeoAgentRowPresentation) -> some View {
        if let label = presentation.lastActive {
            Text(label)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(presentation.lastActiveSpoken ?? label)
        }
    }

    private func detailLine(_ presentation: LeoAgentRowPresentation) -> some View {
        Text(presentation.detail.text)
            .font(.caption)
            .foregroundStyle(presentation.detailInk.style(isSelected: isSelected))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(presentation.detail.text)
            .frame(height: LeoAgentRowMetrics.detailLineHeight, alignment: .leading)
    }
}
