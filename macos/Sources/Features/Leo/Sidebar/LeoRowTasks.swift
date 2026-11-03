import Foundation
import LeoKit

/// An agent's tasks as a row carries them: the tasks the daemon reported
/// plus the ETA `LeoTaskETA` derived for each (by task id).
struct LeoRowTasks: Equatable, Sendable {
    static let none = LeoRowTasks(tasks: [], etaAt: [:])

    let tasks: [LeoAgentTask]
    let etaAt: [String: Date]

    var isEmpty: Bool { tasks.isEmpty }
    /// The task the compact surfaces show.
    var primary: LeoAgentTask? { LeoAgentTasks.primary(tasks) }
    /// The `+N` count: every task but the primary one.
    var extraCount: Int { LeoAgentTasks.extraCount(tasks) }

    func eta(for task: LeoAgentTask) -> Date? { etaAt[task.id] }
}
