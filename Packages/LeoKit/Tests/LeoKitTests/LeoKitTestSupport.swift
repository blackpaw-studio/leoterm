import Foundation
import Testing

/// Polls until `condition` holds. The timeout is only a failure ceiling: a passing test returns as
/// soon as the condition is true, so it is generous enough to ride out a starved 3-core CI runner.
/// The first spins only yield (a condition another task is about to satisfy usually holds within
/// a few scheduler turns, with no wait at all); after that it sleeps 1 ms between polls. The
/// condition runs on the caller's actor, so a `@MainActor` test can read main-actor state directly.
func awaitCondition(
    timeout: TimeInterval = 10,
    message: String = "Condition was not satisfied",
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    var spins = 0

    repeat {
        if await condition() { return }
        spins += 1
        if spins < 200 { await Task.yield() } else { try? await Task.sleep(nanoseconds: 1_000_000) }
    } while Date() < deadline

    Issue.record("\(message) within \(timeout) seconds")
}

/// Runs blocking work (child processes, pipe reads) on a dispatch thread instead of a Swift
/// cooperative-pool thread. The pool is only as wide as the CPU count (3 on a hosted runner), so
/// blocking it (process waits, socket reads) starves every other test's `Task.sleep` /
/// `awaitCondition` wake-up past its wall-clock deadline.
func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result(catching: work)) }
    }
}
