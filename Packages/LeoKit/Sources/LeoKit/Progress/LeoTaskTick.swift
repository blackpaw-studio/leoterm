import Foundation

/// When a surface that shows task durations ("42s", "4m") next needs to
/// redraw. A duration under a minute reads in seconds, so it needs a tick on
/// every whole second; once everything shown is in minutes, a coarse tick is
/// enough. Pure: callers feed it `now` and drive their own timeline.
public enum LeoTaskTick {
    /// How often minute-grained text is refreshed.
    public static let coarse: TimeInterval = 15
    /// A duration at or under this is shown in seconds.
    static let secondsLimit: TimeInterval = 60
    /// Switch to per-second ticks a hair before a duration reads in seconds.
    private static let margin: TimeInterval = 1

    /// The next moment after `now` to redraw. Ticks sit on a fixed grid (whole
    /// seconds, or multiples of `coarse`), so the schedule is the same however
    /// often the view rebuilds it. `etaAt` is the estimate by task id.
    public static func next(after now: Date, tasks: [LeoAgentTask], etaAt: [String: Date]) -> Date {
        let shown = shownDurations(tasks, etaAt: etaAt, now: now)
        if shown.contains(where: { $0.value <= secondsLimit + margin }) {
            return grid(after: now, step: 1)
        }
        let crossings = shown.filter { $0.isCountdown }.map { now.addingTimeInterval($0.value - secondsLimit) }
        return min(grid(after: now, step: coarse), crossings.min() ?? .distantFuture)
    }

    private struct Shown {
        let value: TimeInterval
        /// True for a remaining time, which shrinks into seconds; the rest grow.
        let isCountdown: Bool
    }

    private static func shownDurations(_ tasks: [LeoAgentTask], etaAt: [String: Date], now: Date) -> [Shown] {
        tasks.flatMap { task -> [Shown] in
            if let ended = task.endedAt, task.hasEnded { return [Shown(value: now.timeIntervalSince(ended), isCountdown: false)] }
            var shown = [Shown(value: now.timeIntervalSince(task.startedAt), isCountdown: false)]
            if task.stale {
                shown.append(Shown(value: now.timeIntervalSince(task.updatedAt), isCountdown: false))
            } else if let eta = etaAt[task.id] ?? task.etaAt, eta > now {
                shown.append(Shown(value: eta.timeIntervalSince(now), isCountdown: true))
            }
            return shown
        }
    }

    private static func grid(after now: Date, step: TimeInterval) -> Date {
        let slot = (now.timeIntervalSinceReferenceDate / step).rounded(.down) + 1
        return Date(timeIntervalSinceReferenceDate: slot * step)
    }
}
