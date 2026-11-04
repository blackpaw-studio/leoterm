import SwiftUI
import LeoKit

/// The chat panel's card (B): a translucent card docked top-right listing
/// running and failed tasks across every agent. Expanded by default; the
/// collapsed choice is remembered on this Mac.
struct LeoProgressPanelView: View {
    /// The list scrolls past this; the header stays fixed. Leaves room for the
    /// pane header above and the composer below in a short window.
    static let listMaxHeight: CGFloat = 320
    static let collapsedKey = "leo.progressPanel.collapsed"

    let model: LeoProgressPanelModel
    let select: (LeoAgentRow.ID) -> Void
    let dismiss: (LeoProgressPanelModel.Entry) -> Void
    @AppStorage(LeoProgressPanelView.collapsedKey) private var isCollapsed = false

    var body: some View {
        if !model.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header
                if !isCollapsed {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(model.entries) { entry in row(entry, now: context.date) }
                            }
                        }
                        .scrollIndicators(.automatic)
                        .frame(maxHeight: Self.listMaxHeight)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(width: 300, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }

    private var header: some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { isCollapsed.toggle() } } label: {
            HStack(spacing: 6) {
                Text(isCollapsed ? model.collapsedTitle : "Tasks \(model.runningCount) running").font(.subheadline.weight(.semibold))
                if model.failedCount > 0 {
                    Text("\(model.failedCount) failed").font(.subheadline).foregroundStyle(.red)
                }
                Spacer(minLength: 4)
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Show tasks" : "Hide tasks")
    }

    private func row(_ entry: LeoProgressPanelModel.Entry, now: Date) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.emoji ?? "•").font(.callout).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                LeoTaskDetailRow(task: entry.task, etaAt: entry.etaAt, now: now, dismiss: { dismiss(entry) })
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { select(entry.agent) }
    }
}
