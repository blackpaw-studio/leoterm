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
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    private func header(_ primary: LeoAgentTask, now: Date) -> some View {
        let kind = LeoAgentRowPresentation.Progress.Kind(primary)
        return Button { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } } label: {
            HStack(spacing: 8) {
                Text(agentName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(LeoTaskText.summary(primary, etaAt: tasks.eta(for: primary), now: now))
                    .font(.caption).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(kind == .failed ? .red : .primary)
                LeoTaskBar(kind: kind).frame(width: 90)
                if let badge = LeoTaskText.extraBadge(tasks.extraCount) {
                    Text(badge).font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide tasks" : "Show tasks")
    }
}
