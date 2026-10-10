import SwiftUI

/// An agent row: a leading state symbol, then the name line (the name, the
/// surfaced-files glyph, and the last-active time, a state word, or a
/// spinner while an action is pending) and, for states that have one, a
/// detail line aligned with the name. Each line is pinned to a fixed height
/// and whether there is a second line is fixed per state, so the row never
/// resizes as its content changes.
struct LeoAgentRowContent: View {
    let row: LeoAgentRow
    let error: String?
    let isSelected: Bool
    let isPending: Bool
    /// Name characters the search query matched, drawn bold.
    let nameHighlights: [Int]
    /// This row's unseen surfaced files, newest last.
    let pendingSurfacedFiles: [LeoSurfacedFile]
    /// Whether the row sits in the Working section (grouped by attention):
    /// one line, with the word trailing.
    var inWorkingSection = false

    var body: some View {
        let presentation = LeoAgentRowPresentation(row: row, error: error, inWorkingSection: inWorkingSection)
        HStack(alignment: .top, spacing: LeoAgentRowMetrics.symbolSpacing) {
            LeoAgentStateSymbolView(state: presentation.state, isSelected: isSelected)
            VStack(alignment: .leading, spacing: LeoAgentRowMetrics.lineSpacing) {
                nameLine(presentation)
                if presentation.state.hasSecondLine { detailLine(presentation) }
            }
        }
        .padding(.vertical, LeoAgentRowMetrics.verticalPadding)
        .help(presentation.help)
    }

    private func nameLine(_ presentation: LeoAgentRowPresentation) -> some View {
        HStack(spacing: 6) {
            nameText
                .fontWeight(.medium)
                .foregroundStyle(presentation.isNameDimmed ? .secondary : .primary)
                .lineLimit(1)
                .accessibilityLabel(presentation.accessibilityLabel(name: row.name))
            Spacer(minLength: 4)
            surfacedFilesGlyph
            trailing(presentation.state)
        }
        .frame(height: LeoAgentRowMetrics.nameLineHeight)
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
            .foregroundStyle(detailInk(presentation).style(isSelected: isSelected))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(presentation.detail.text)
            .frame(height: LeoAgentRowMetrics.detailLineHeight, alignment: .leading)
    }

    /// The state's ink; the placeholder when there is nothing to say stays
    /// a step quieter.
    private func detailInk(_ presentation: LeoAgentRowPresentation) -> LeoInk {
        if case .fallback = presentation.detail, presentation.state.detailInk == .secondary { return .tertiary }
        return presentation.state.detailInk
    }

    /// Static, secondary-colored: files the agent surfaced that haven't
    /// been opened. Calm on purpose -- no tint, no motion; it isn't "needs
    /// input". The tooltip lists them.
    @ViewBuilder private var surfacedFilesGlyph: some View {
        if let indicator = LeoSurfacedFilesIndicator(pending: pendingSurfacedFiles) {
            HStack(spacing: 2) {
                Image(systemName: LeoSurfacedFilesIndicator.symbolName)
                Text(indicator.countText).monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help(indicator.tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(indicator.accessibilityLabel)
        }
    }
}
