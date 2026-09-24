import Foundation

/// Buffers `agentActivity` SSE events between the first arrival and a flush,
/// so a chatty agent's rapid activity updates can be applied in one merge +
/// emission instead of one per event. Last write wins per agent name --
/// non-activity events aren't buffered at all (`add` reports `false`).
struct LeoActivityCoalescer: Sendable {
    private var buffered: [String: LeoObserveEvent] = [:]

    /// True while nothing is currently buffered.
    private(set) var isEmpty = true

    /// Adds `event` to the buffer, overwriting any earlier event already
    /// buffered for the same agent. Returns `true` exactly when this is the
    /// first event added since the last `drain()` -- the caller uses that
    /// signal to start a single flush timer for the whole window, not one
    /// per event.
    @discardableResult
    mutating func add(_ event: LeoObserveEvent) -> Bool {
        guard case let .agentActivity(_, _, name, _, _, _) = event else { return false }
        let isFirst = isEmpty
        buffered[name] = event
        isEmpty = false
        return isFirst
    }

    /// Removes and returns every buffered event, resetting the buffer.
    mutating func drain() -> [LeoObserveEvent] {
        defer {
            buffered = [:]
            isEmpty = true
        }
        return Array(buffered.values)
    }
}
