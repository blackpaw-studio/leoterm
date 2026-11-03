import Foundation

/// Derives an ETA for a task. An agent-supplied `eta_at` always wins;
/// otherwise a determinate running task gets a linear estimate from the
/// percent samples this value has seen. A value type: the caller owns it and
/// feeds it `now`, so nothing here reads a clock.
public struct LeoTaskETA: Equatable, Sendable {
    /// Samples must span at least this long before an estimate is shown.
    public static let minimumSpan: TimeInterval = 30
    static let maxSamples = 64

    struct Key: Hashable, Sendable {
        let agent: String
        let id: String
        let startedAt: Date
    }

    struct Sample: Equatable, Sendable {
        let time: Date
        let percent: Double
    }

    private var samples: [Key: [Sample]] = [:]

    public init() {}

    /// Records the task's current percent. Only a running determinate task
    /// is sampled, and only when its percent changed, so a plateau does not
    /// push the useful history out. A new `started_at` is a fresh run: the
    /// old run's samples are dropped.
    public mutating func observe(agent: String, task: LeoAgentTask, now: Date) {
        let key = Key(agent: agent, id: task.id, startedAt: task.startedAt)
        samples = samples.filter { $0.key.agent != agent || $0.key.id != task.id || $0.key == key }
        guard task.isRunning, task.mode == .determinate, let percent = task.percent else { return }
        var list = samples[key] ?? []
        guard list.last?.percent != percent else { return }
        list.append(Sample(time: now, percent: percent))
        samples[key] = Array(list.suffix(Self.maxSamples))
    }

    /// Drops everything known about a task (it was removed).
    public mutating func forget(agent: String, id: String) {
        samples = samples.filter { $0.key.agent != agent || $0.key.id != id }
    }

    /// When the task should finish; nil when unknown, flat, falling, or
    /// the task is no longer running. Never earlier than `now`.
    public func etaAt(agent: String, task: LeoAgentTask, now: Date) -> Date? {
        guard task.isRunning else { return nil }
        if let supplied = task.etaAt { return supplied }
        let key = Key(agent: agent, id: task.id, startedAt: task.startedAt)
        guard task.mode == .determinate, let list = samples[key],
              let first = list.first, let last = list.last,
              last.time.timeIntervalSince(first.time) >= Self.minimumSpan,
              last.percent > first.percent
        else { return nil }
        let rate = (last.percent - first.percent) / last.time.timeIntervalSince(first.time)
        let eta = last.time.addingTimeInterval(max(100 - last.percent, 0) / rate)
        return max(eta, now)
    }

    /// Time since the run started, for an indeterminate running task.
    public static func elapsed(of task: LeoAgentTask, now: Date) -> TimeInterval? {
        guard task.isRunning, task.mode == .indeterminate else { return nil }
        return max(now.timeIntervalSince(task.startedAt), 0)
    }
}
