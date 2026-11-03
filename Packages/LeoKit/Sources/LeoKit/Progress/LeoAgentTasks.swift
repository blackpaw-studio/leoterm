import Foundation

/// Which of an agent's tasks the compact surfaces (row, header strip) show.
public enum LeoAgentTasks {
    /// An undismissed failed task first, else the most recently updated
    /// running one, else the most recent succeeded or cancelled one. Ties
    /// break by id so every surface agrees.
    public static func primary(_ tasks: [LeoAgentTask]) -> LeoAgentTask? {
        let failed = tasks.filter { $0.state == .failed }
        if let pick = newest(failed, by: \.recency) { return pick }
        let running = tasks.filter(\.isRunning)
        if let pick = newest(running, by: \.updatedAt) { return pick }
        return newest(tasks, by: \.recency)
    }

    /// The `+N` badge: every task that is not the primary one.
    public static func extraCount(_ tasks: [LeoAgentTask]) -> Int {
        max(tasks.count - 1, 0)
    }

    private static func newest(_ tasks: [LeoAgentTask], by date: (LeoAgentTask) -> Date) -> LeoAgentTask? {
        tasks.min { lhs, rhs in
            let (l, r) = (date(lhs), date(rhs))
            return l != r ? l > r : lhs.id < rhs.id
        }
    }
}

extension LeoAgentTask {
    /// When it ended, else when it last changed.
    fileprivate var recency: Date { endedAt ?? updatedAt }
}
