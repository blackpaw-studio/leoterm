import ComposableArchitecture
import Foundation
import LeoKit

extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
    /// The task panel over Chats is collapsed to its header (per device).
    public static var progressPanelCollapsed: Self { Self[.appStorage("progressPanelCollapsed"), default: false] }
}

/// One row of the floating task panel: a task and the agent running it.
public struct TaskPanelRow: Equatable, Identifiable, Sendable {
    public let ref: AgentRef
    public let agent: Agent
    public let task: LeoAgentTask
    public let etaAt: Date?

    public var id: String { "\(ref.daemonID)/\(ref.name)/\(task.id)" }
}

extension Fleet.State {
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
                    TaskPanelRow(ref: AgentRef(daemonID: session.id, name: agent.name), agent: agent, task: $0, etaAt: agent.taskETAs[$0.id])
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
