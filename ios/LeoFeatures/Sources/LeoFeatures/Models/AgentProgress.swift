import Foundation
import LeoKit

/// What an Agents list row shows for an agent's tasks (cell 2): one line of
/// text under the subtitle and a thin bar. Only the primary task is drawn;
/// the rest are a `+N` badge.
public struct AgentProgress: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// A fraction 0...1 of a running task.
        case determinate(Double)
        case indeterminate
        /// Running but silent for too long: the bar is dimmed.
        case stale(Double?)
        /// A full red bar.
        case failed
    }

    public let text: String
    public let style: Style
    /// `+N` for the agent's other tasks.
    public let badge: String?
}

extension Agent {
    /// The progress line for the row, or nil when there is nothing to show:
    /// no tasks, a stopped agent, or an agent that needs the user (attention
    /// wins over progress).
    public func progress(now: Date) -> AgentProgress? {
        guard !isStopped, !priority.needsAttention, let task = LeoAgentTasks.primary(tasks) else { return nil }
        return AgentProgress(
            text: LeoTaskText.summary(task, etaAt: taskETAs[task.id], now: now),
            style: Self.style(of: task),
            badge: LeoTaskText.extraBadge(LeoAgentTasks.extraCount(tasks))
        )
    }

    /// How a task's bar is drawn; shared by the row, the detail and the panel.
    public static func style(of task: LeoAgentTask) -> AgentProgress.Style {
        let fraction = task.mode == .determinate ? task.percent.map { $0 / 100 } : nil
        switch task.state {
        case .failed: return .failed
        case .succeeded, .cancelled: return .determinate(1)
        case .running:
            if task.stale { return .stale(fraction) }
            return fraction.map(AgentProgress.Style.determinate) ?? .indeterminate
        }
    }
}

extension Agent {
    /// The line under a task's title in the detail and the panel:
    /// `Compiling 412/980 · 62% · 4m`, `Failed · exit 2`, `Done`.
    public func taskDetailLine(_ task: LeoAgentTask, now: Date) -> String {
        Self.taskDetailLine(task, etaAt: taskETAs[task.id], now: now)
    }

    public static func taskDetailLine(_ task: LeoAgentTask, etaAt: Date?, now: Date) -> String {
        var parts: [String] = []
        switch task.state {
        case .failed: parts.append("Failed")
        case .succeeded: parts.append("Done")
        case .cancelled: parts.append("Cancelled")
        case .running: break
        }
        if let status = task.status { parts.append(status) }
        guard task.isRunning else { return parts.joined(separator: " · ") }
        if let percent = task.percent, task.mode == .determinate { parts.append(LeoTaskText.percent(percent)) }
        if task.stale {
            parts.append("stale")
        } else if task.mode == .determinate {
            if let eta = etaAt, eta > now { parts.append(LeoTaskText.duration(eta.timeIntervalSince(now))) }
        } else if let elapsed = LeoTaskETA.elapsed(of: task, now: now) {
            parts.append(LeoTaskText.duration(elapsed))
        }
        return parts.joined(separator: " · ")
    }
}
