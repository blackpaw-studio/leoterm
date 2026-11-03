import Foundation
import LeoKit

/// The wording of one task in the detail surfaces (popover, header strip,
/// chat card): a percent, a status line and a timing line. Pure.
enum LeoTaskDetailText {
    /// "62%" for a determinate task, nil otherwise; a succeeded one reads 100%.
    static func percent(_ task: LeoAgentTask) -> String? {
        if task.state == .succeeded { return LeoTaskText.percent(100) }
        guard task.mode == .determinate, let percent = task.percent else { return nil }
        return LeoTaskText.percent(percent)
    }

    /// The task's own words, or what the state says when it gave none.
    static func status(_ task: LeoAgentTask, now: Date) -> String? {
        if task.stale, task.isRunning { return "No update for \(LeoTaskText.duration(max(now.timeIntervalSince(task.updatedAt), 0)))" }
        if let status = task.status { return status }
        switch task.state {
        case .running: return nil
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    /// "4m · ETA ~3m" while running, "6m ago" once ended.
    static func timing(_ task: LeoAgentTask, etaAt: Date?, now: Date) -> String {
        guard let ended = task.endedAt, task.hasEnded else {
            var parts = [LeoTaskText.duration(max(now.timeIntervalSince(task.startedAt), 0))]
            if !task.stale, let etaAt, etaAt > now { parts.append("ETA ~\(LeoTaskText.duration(etaAt.timeIntervalSince(now)))") }
            return parts.joined(separator: " · ")
        }
        return "\(LeoTaskText.duration(max(now.timeIntervalSince(ended), 0))) ago"
    }

    /// Count by state: "2 running · 1 failed", "1 done"; empty states are left out.
    static func header(_ tasks: [LeoAgentTask]) -> String {
        let states: [(LeoAgentTask.State, String)] = [(.running, "running"), (.failed, "failed"), (.succeeded, "done"), (.cancelled, "cancelled")]
        return states
            .map { state, label in (tasks.filter { $0.state == state }.count, label) }
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: " · ")
    }
}
