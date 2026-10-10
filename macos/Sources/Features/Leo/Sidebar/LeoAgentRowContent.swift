import SwiftUI

/// An agent row's two lines. Line 1 is the name, the surfaced-files glyph
/// and the last-active time (or a spinner while an action is pending);
/// line 2 is the state pill and one detail string. Both lines are pinned to
/// a fixed height, so the row never resizes as its content changes.
struct LeoAgentRowContent: View {
    let row: LeoAgentRow
    let error: String?
    let isSelected: Bool
    let isPending: Bool
    /// Name characters the search query matched, drawn bold.
    let nameHighlights: [Int]
    /// This row's unseen surfaced files, newest last.
    let pendingSurfacedFiles: [LeoSurfacedFile]

    var body: some View {
        let presentation = LeoAgentRowPresentation(row: row, error: error)
        VStack(alignment: .leading, spacing: LeoAgentRowMetrics.lineSpacing) {
            nameLine(presentation)
            detailLine(presentation)
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
            trailing
        }
        .frame(height: LeoAgentRowMetrics.nameLineHeight)
    }

    private var nameText: Text {
        LeoFuzzyMatcher.highlightRuns(name: row.name, offsets: nameHighlights).reduce(Text("")) { text, run in
            text + Text(run.text).fontWeight(run.isMatched ? .bold : nil)
        }
    }

    /// A pending action replaces the time. Only a row with a "last active"
    /// time re-renders it, once a minute -- never per event.
    @ViewBuilder private var trailing: some View {
        if isPending {
            ProgressView().controlSize(.small)
        } else if row.metadata?.lastActiveAt != nil || row.metadata?.isWorking == true {
            TimelineView(.everyMinute) { context in
                timeText(LeoAgentRowPresentation(row: row, error: error, now: context.date))
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
        HStack(spacing: 6) {
            LeoAgentPillView(pill: presentation.pill, isSelected: isSelected)
            detailText(presentation.detail)
        }
        .frame(height: LeoAgentRowMetrics.detailLineHeight, alignment: .leading)
    }

    private func detailText(_ detail: LeoAgentRowPresentation.Detail) -> some View {
        Text(detail.text)
            .font(.caption)
            .foregroundStyle(detailStyle(detail))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(detail.text)
    }

    private func detailStyle(_ detail: LeoAgentRowPresentation.Detail) -> AnyShapeStyle {
        switch detail {
        case .error: AnyShapeStyle(LeoTint.red.color)
        case .fallback: AnyShapeStyle(.tertiary)
        default: AnyShapeStyle(.secondary)
        }
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
