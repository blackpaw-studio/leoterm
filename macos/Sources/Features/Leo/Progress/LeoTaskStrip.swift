import SwiftUI
import LeoKit

/// The strip above the selected agent's terminal (B): one line with the
/// primary task, or the whole list when expanded. Not drawn when the agent
/// has no task.
struct LeoTaskStrip: View {
    let agentName: String
    let tasks: LeoRowTasks
    let dismiss: (LeoAgentTask) -> Void
    @State private var isExpanded = false

    var body: some View {
        if let primary = tasks.primary {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    header(primary, now: context.date)
                    if isExpanded {
                        LeoTaskListView(tasks: tasks, now: context.date, dismiss: dismiss)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, isExpanded ? 6 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    private func header(_ primary: LeoAgentTask, now: Date) -> some View {
        let kind = LeoAgentRowPresentation.Progress.Kind(primary)
        return Button { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } } label: {
            HStack(alignment: .center, spacing: 8) {
                Text(agentName).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                // Expanded, the list below says it all: just the label here.
                if !isExpanded {
                    Text([primary.title, primary.status].compactMap { $0 }.joined(separator: " · "))
                        .font(.body).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(kind == .failed ? .red : .primary)
                        .layoutPriority(1)
                    LeoTaskBar(kind: kind, height: 6).frame(minWidth: 120, maxWidth: .infinity)
                    Text(LeoTaskDetailText.trailing(primary, etaAt: tasks.eta(for: primary), now: now))
                        .font(.subheadline).monospacedDigit().lineLimit(1).fixedSize()
                        .foregroundStyle(kind == .failed ? .red : .secondary)
                    if let badge = LeoTaskText.extraBadge(tasks.extraCount) {
                        Text(badge).font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                if isExpanded { Spacer(minLength: 4) }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide tasks" : "Show tasks")
    }
}
