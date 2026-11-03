import ComposableArchitecture
import Foundation
import LeoKit

extension SharedReaderKey where Self == AppStorageKey<Bool?> {
    /// Whether the user last left the task panel over Chats collapsed to its
    /// header (per device); nil until they toggle it, so the width default applies.
    public static var progressPanelChoice: Self { .appStorage("progressPanelCollapsed") }
}

/// One row of the floating task panel: a task and the agent running it.
public struct TaskPanelRow: Equatable, Identifiable, Sendable {
    public let ref: AgentRef
    /// Only what the panel draws, so live activity on the agent never changes a row.
    public let displayName: String
    public let emoji: String?
    public let task: LeoAgentTask
    public let etaAt: Date?

    public var id: String { "\(ref.daemonID)/\(ref.name)/\(task.id)" }
}

extension Fleet.State {
    /// What the panel shows: the user's last choice, else collapsed at compact
    /// width (a full-width card) and expanded at regular width (the corner card).
    public var isProgressPanelCollapsed: Bool { progressPanelChoice ?? isCompactWidth }

    /// Some agent has a running task, so its text needs a moving clock.
    var hasRunningTask: Bool {
        sessions.contains { $0.agents.contains { $0.tasks.contains(where: \.isRunning) } }
    }

    /// Running and undismissed failed tasks across every agent: failed first,
    /// then the most recently updated. Ended-and-lingering ones are left out.
    public var taskPanelRows: [TaskPanelRow] {
        let rows = sessions.flatMap { session in
            session.agents.filter { !$0.isStopped }.flatMap { agent in
                agent.tasks.filter { $0.isRunning || $0.state == .failed }.map {
                    TaskPanelRow(ref: AgentRef(daemonID: session.id, name: agent.name), displayName: agent.displayName, emoji: agent.appearance?.emoji, task: $0, etaAt: agent.taskETAs[$0.id])
                }
            }
        }
        return rows.sorted { lhs, rhs in
            let (l, r) = (lhs.task, rhs.task)
            if (l.state == .failed) != (r.state == .failed) { return l.state == .failed }
            if l.updatedAt != r.updatedAt { return l.updatedAt > r.updatedAt }
            return lhs.id < rhs.id
        }
    }

    /// "Tasks 3 · 62%": the count, and the percent of the first running
    /// determinate task when there is one.
    public var taskPanelHeader: String {
        let rows = taskPanelRows
        let lead = rows.first { $0.task.isRunning && $0.task.mode == .determinate && $0.task.percent != nil }
        return ["Tasks \(rows.count)", lead?.task.percent.map(LeoTaskText.percent)].compactMap { $0 }.joined(separator: " · ")
    }
}
