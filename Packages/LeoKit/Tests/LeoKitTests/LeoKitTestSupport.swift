import Foundation
import Testing

func awaitCondition(
    timeout: TimeInterval = 1,
    message: String = "Condition was not satisfied",
    _ condition: @escaping @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)

    repeat {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
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
