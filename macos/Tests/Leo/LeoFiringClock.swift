import Foundation

/// An injected `sleep` that holds every sleep until the test fires it, by
/// length -- so firing, say, a coalescing window never also fires a fetch
/// deadline or an attention tick. A cancelled sleep leaves at once
/// (synchronously, in `cancel()`), so `pending` is exact.
final class LeoFiringClock: @unchecked Sendable {
    private struct Sleeper {
        let nanoseconds: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var sleepers: [Int: Sleeper] = [:]
    private var cancelledEarly: Set<Int> = []
    private var nextID = 0

    /// The ids of the sleeps of this length still waiting, oldest first.
    func pending(_ nanoseconds: UInt64) -> [Int] {
        lock.withLock { sleepers.filter { $0.value.nanoseconds == nanoseconds }.keys.sorted() }
    }

    func sleep(_ nanoseconds: UInt64) async throws {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if cancelledEarly.remove(id) != nil { return true }
                    sleepers[id] = Sleeper(nanoseconds: nanoseconds, continuation: continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                guard let sleeper = sleepers.removeValue(forKey: id) else { cancelledEarly.insert(id); return nil }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Wakes every sleep of this length.
    func fire(_ nanoseconds: UInt64) {
        let due = lock.withLock { () -> [Sleeper] in
            let due = sleepers.filter { $0.value.nanoseconds == nanoseconds }
            due.keys.forEach { sleepers.removeValue(forKey: $0) }
            return Array(due.values)
        }
        due.forEach { $0.continuation.resume() }
    }
}

/// Re-checks `condition` until it holds. No deadline: the suite's time
/// limit is the hang guard, so a slow machine only makes this slower. When
/// the limit cancels the test, this throws instead of spinning on.
func until(_ condition: @Sendable () async -> Bool) async throws {
    while !(await condition()) {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
