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

    /// "3 active · 2 finished"; a missing half is left out.
    static func header(_ tasks: [LeoAgentTask]) -> String {
        let active = tasks.filter(\.isRunning).count
        let finished = tasks.count - active
        return [active > 0 ? "\(active) active" : nil, finished > 0 ? "\(finished) finished" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
