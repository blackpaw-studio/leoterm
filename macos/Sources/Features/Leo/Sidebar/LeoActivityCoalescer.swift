import Foundation

/// Buffers `agentActivity` SSE events between the first arrival and a flush,
/// so a chatty agent's rapid activity updates can be applied in one merge +
/// emission instead of one per event. Last write wins per agent name --
/// non-activity events aren't buffered at all (`add` reports `false`).
/// The newest "working" stamp per agent survives a later overwrite, so the
/// sidebar's last-activity time isn't lost to an idle event (B-010).
struct LeoActivityCoalescer: Sendable {
    struct Batch: Sendable {
        let events: [LeoObserveEvent]
        let latestWorkingAt: [String: Date]
    }

    private var buffered: [String: LeoObserveEvent] = [:]
    private var latestWorkingAt: [String: Date] = [:]

    /// True while nothing is currently buffered.
    private(set) var isEmpty = true

    /// Adds `event` to the buffer, overwriting any earlier event already
    /// buffered for the same agent. Returns `true` exactly when this is the
    /// first event added since the last `drain()` -- the caller uses that
    /// signal to start a single flush timer for the whole window, not one
    /// per event.
    @discardableResult
    mutating func add(_ event: LeoObserveEvent) -> Bool {
        guard case let .agentActivity(_, at, name, activity, _, _) = event else { return false }
        let isFirst = isEmpty
        buffered[name] = event
        if activity == .working, let stamp = LeoTimestamp.parse(at) {
            latestWorkingAt[name] = max(latestWorkingAt[name] ?? stamp, stamp)
        }
        isEmpty = false
        return isFirst
    }

    /// Removes and returns every buffered event, resetting the buffer.
    mutating func drain() -> [LeoObserveEvent] { drainBatch().events }

    /// `drain()`, plus each agent's newest working stamp in the window.
    mutating func drainBatch() -> Batch {
        defer {
            buffered = [:]
            latestWorkingAt = [:]
            isEmpty = true
        }
        return Batch(events: Array(buffered.values), latestWorkingAt: latestWorkingAt)
    }
}
