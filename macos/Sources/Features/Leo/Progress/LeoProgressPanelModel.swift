import Foundation
import LeoKit

/// The chat panel's card (B): running and undismissed failed tasks across
/// every agent on every machine. Pure; the view only draws it.
struct LeoProgressPanelModel: Equatable {
    struct Entry: Equatable, Identifiable {
        let agent: LeoAgentRow.ID
        let displayName: String
        let emoji: String?
        let task: LeoAgentTask
        let etaAt: Date?

        var id: String { "\(agent.host.displayName)/\(agent.name)/\(task.id)" }
    }

    /// Failed first (they need dismissing), then running by most recent
    /// update; ties by agent name then task id so the list never reshuffles.
    let entries: [Entry]

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    var failedCount: Int { entries.filter { $0.task.state == .failed }.count }
    var runningCount: Int { count - failedCount }

    init(rows: [LeoAgentRow]) {
        entries = rows.flatMap { row in
            row.tasks.tasks.filter { $0.isRunning || $0.state == .failed }.map {
                Entry(agent: row.id, displayName: row.displayName, emoji: row.appearance?.emoji, task: $0, etaAt: row.tasks.eta(for: $0))
            }
        }.sorted(by: Self.precedes)
    }

    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let (lFailed, rFailed) = (lhs.task.state == .failed, rhs.task.state == .failed)
        if lFailed != rFailed { return lFailed }
        if lhs.task.updatedAt != rhs.task.updatedAt { return lhs.task.updatedAt > rhs.task.updatedAt }
        return lhs.id < rhs.id
    }

    /// The collapsed header's mean percent over determinate running tasks,
    /// "Tasks 3 · 62%"; nil percent when none has one.
    var collapsedTitle: String {
        let percents = entries.filter { $0.task.isRunning && $0.task.mode == .determinate }.compactMap(\.task.percent)
        let head = "Tasks \(count)"
        guard !percents.isEmpty else { return head }
        return "\(head) · \(LeoTaskText.percent(percents.reduce(0, +) / Double(percents.count)))"
    }
}
