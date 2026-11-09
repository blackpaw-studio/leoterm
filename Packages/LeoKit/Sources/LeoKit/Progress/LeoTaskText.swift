import Foundation

/// The one-line wording for a task on the compact surfaces
/// (`title · status · 62% · 4m`), shared by Mac and iOS.
public enum LeoTaskText {
    private static let separator = " · "

    /// `etaAt` is the estimate from `LeoTaskETA` (or the task's own);
    /// nil or past shows no remaining time. A stale task shows "stale"
    /// instead, since its ETA is no longer trustworthy.
    public static func summary(_ task: LeoAgentTask, etaAt: Date?, now: Date) -> String {
        switch task.state {
        case .failed: return ended("Failed", task)
        case .succeeded: return ended("Done", task)
        case .cancelled: return ended("Cancelled", task)
        case .running: break
        }
        var parts = [task.title]
        if let status = task.status { parts.append(status) }
        if let percent = task.percent, task.mode == .determinate { parts.append(Self.percent(percent)) }
        if task.stale {
            parts.append("stale")
        } else if task.mode == .determinate {
            if let etaAt, etaAt > now { parts.append(duration(etaAt.timeIntervalSince(now))) }
        } else if let elapsed = LeoTaskETA.elapsed(of: task, now: now) {
            parts.append(duration(elapsed))
        }
        return parts.joined(separator: separator)
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(min(max(value, 0), 100).rounded()))%"
    }

    /// "45s", "4m", "1h 5m". Minutes round down once past a minute.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        if total < 1 { return "<1s" }
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }

    private static func ended(_ label: String, _ task: LeoAgentTask) -> String {
        "\(label): \(task.title)"
    }
}
