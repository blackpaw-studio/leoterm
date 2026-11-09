import Foundation
import LeoKit

/// What an Agents list row shows for an agent's tasks: a small circular
/// indicator in the cell's trailing area and the task's text in place of the
/// summary. The rules live in LeoKit (`LeoTaskRowPresentation`), shared with
/// the Mac sidebar. The Tasks panel and detail keep their bars.
public struct AgentProgress: Equatable, Sendable {
    /// How a task's bar is drawn (the panel and the detail).
    public enum Style: Equatable, Sendable {
        /// A fraction 0...1 of a running task.
        case determinate(Double)
        case indeterminate
        /// Running but silent for too long: the bar is dimmed.
        case stale(Double?)
        /// A full red bar.
        case failed
    }

    /// The trailing indicator; nil draws nothing.
    public let indicator: LeoTaskIndicator?
    /// Replaces the row's summary; nil keeps the summary.
    public let text: String?
    /// The tail of `text` that stays whole when the line is too long; the
    /// title before it is what truncates.
    public let textSuffix: String?
    /// "Build Leo.app, 62 percent", "In progress", "Stalled" or "Failed".
    public let spokenValue: String?
    /// The full one-line summary, for the cell's accessibility hint.
    public let tooltip: String
}

extension Agent {
    /// The row's task presentation, or nil when there is nothing to show:
    /// no tasks, a stopped agent, or an agent that needs the user (attention
    /// wins over progress).
    public func progress(now: Date) -> AgentProgress? {
        guard !isStopped, !priority.needsAttention else { return nil }
        guard let summary = LeoTaskRowPresentation.summary(
            tasks, etaAt: taskETAs, agentIsInError: priority == .errored, now: now
        ) else { return nil }
        return AgentProgress(
            indicator: summary.indicator, text: summary.detail, textSuffix: summary.detailSuffix, spokenValue: summary.spokenValue, tooltip: summary.tooltip)
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
