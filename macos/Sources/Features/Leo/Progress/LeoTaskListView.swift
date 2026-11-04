import SwiftUI
import LeoKit

/// Every task of one agent: the popover on the row's bar (A) and the
/// expanded header strip (B). Active ones first, then finished; a failed
/// one carries Dismiss.
struct LeoTaskListView: View {
    let tasks: LeoRowTasks
    let now: Date
    let dismiss: (LeoAgentTask) -> Void

    private var ordered: [LeoAgentTask] {
        tasks.tasks.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.id < rhs.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ordered) { task in
                LeoTaskDetailRow(task: task, etaAt: tasks.eta(for: task), now: now) { dismiss(task) }
            }
        }
    }
}

/// One task: title and percent, the bar (or a spinner while the amount is
/// unknown), then status and timing.
struct LeoTaskDetailRow: View {
    let task: LeoAgentTask
    let etaAt: Date?
    let now: Date
    var dismiss: (() -> Void)?

    var body: some View {
        let kind = LeoAgentRowPresentation.Progress.Kind(task)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if kind == .indeterminate { ProgressView().controlSize(.small) }
                Text(task.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let percent = LeoTaskDetailText.percent(task) {
                    Text(percent).font(.subheadline).monospacedDigit().foregroundStyle(kind == .failed ? .red : .secondary)
                }
                if task.state == .failed, let dismiss {
                    Button("Dismiss", action: dismiss).buttonStyle(.link).font(.subheadline)
                }
            }
            if kind != .indeterminate { LeoTaskBar(kind: kind, height: 4) }
            HStack(spacing: 6) {
                if let status = LeoTaskDetailText.status(task, now: now) {
                    Text(status).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(kind == .failed ? .red : .secondary)
                }
                Spacer(minLength: 4)
                Text(LeoTaskDetailText.timing(task, etaAt: etaAt, now: now)).monospacedDigit().foregroundStyle(.tertiary)
            }
            .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The popover on a row's bar: the agent's name, its counts, the list.
struct LeoTaskPopover: View {
    let agentName: String
    let emoji: String?
    let tasks: LeoRowTasks
    let dismiss: (LeoAgentTask) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    if let emoji { Text(emoji) }
                    Text(agentName).font(.headline)
                    Spacer(minLength: 8)
                    Text(LeoTaskDetailText.header(tasks.tasks)).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                LeoTaskListView(tasks: tasks, now: context.date, dismiss: dismiss)
            }
            .padding(12)
            .frame(width: 340)
        }
    }
}
