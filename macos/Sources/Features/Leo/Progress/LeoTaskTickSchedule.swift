import LeoKit
import SwiftUI

/// A `TimelineView` schedule that ticks as often as the task durations on
/// screen need: every second while any reads in seconds, coarsely after.
/// Unlike `.periodic(from: .now, …)` it sits on a fixed grid, so a view
/// rebuilt by a model update does not shift the phase and the seconds count
/// up evenly.
struct LeoTaskTickSchedule: TimelineSchedule {
    let tasks: [LeoAgentTask]
    let etaAt: [String: Date]

    init(_ rowTasks: LeoRowTasks) {
        tasks = rowTasks.tasks
        etaAt = rowTasks.etaAt
    }

    func entries(from start: Date, mode: Mode) -> some Sequence<Date> {
        sequence(first: start) { LeoTaskTick.next(after: $0, tasks: tasks, etaAt: etaAt) }
    }
}
