import Foundation
import Testing

/// Polls until `condition` holds, then returns. The timeout is only a failure ceiling: a passing
/// test returns as soon as the condition is true, so it can be generous.
///
/// It has to be generous because these UI tests run concurrently on one main actor: with a couple
/// of dozen windows open, each test's layout and navigation work queues behind the others', so a
/// wait that takes under a second alone takes tens of seconds on a loaded 3-core runner. A
/// wall-clock ceiling of 10 s failed there where the earlier iteration-counted loop (which stretches
/// with that contention) did not. Polling stays at 5 ms: the condition walks a view hierarchy, and
/// polling faster only adds main-thread load for the other tests. The condition runs on the
/// caller's actor.
func settle(
    timeout: TimeInterval = 120,
    message: String = "Condition was not satisfied",
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)

    repeat {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    } while Date() < deadline

    Issue.record("\(message) within \(timeout) seconds")
}
