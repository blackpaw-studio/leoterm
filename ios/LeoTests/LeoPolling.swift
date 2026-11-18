import Foundation
import Testing

/// Polls until `condition` holds, then returns. The timeout is only a failure ceiling: a passing
/// test returns as soon as the condition is true. The first spins only yield (work another task is
/// about to finish usually lands within a few turns, with no wait); after that it sleeps 1 ms
/// between polls, because a held write or snapshot apply can come from another thread, which
/// `Task.yield` doesn't wait for. The condition runs on the caller's actor.
func settle(
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
        if spins < 200 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(1)) }
    } while Date() < deadline

    Issue.record("\(message) within \(timeout) seconds")
}
