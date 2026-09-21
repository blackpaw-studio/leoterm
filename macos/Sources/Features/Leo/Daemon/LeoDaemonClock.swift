import Foundation

/// Injectable clock for `LeoUnixSocketTransport`'s stream idle-timeout.
/// Production code sleeps for real; tests advance a logical clock
/// synchronously (no real sleeping) and need `sleep(until:)` callers woken
/// the instant the logical clock passes their deadline.
protocol LeoDaemonClock: Sendable {
    func now() -> UInt64
    /// Suspends until `now() >= deadline`, or throws `CancellationError` if
    /// the calling task is cancelled first.
    func sleep(until deadline: UInt64) async throws
}

/// Real wall-clock time via `DispatchTime`/`Task.sleep`.
struct LeoRealClock: LeoDaemonClock {
    func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func sleep(until deadline: UInt64) async throws {
        try Task.checkCancellation()
        let current = now()
        guard deadline > current else { return }
        try await Task.sleep(nanoseconds: deadline - current)
    }
}
