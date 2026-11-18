import Foundation
import Testing

@testable import Ghostty

/// Polls until `condition` holds. The timeout is only a failure ceiling: a passing test returns as
/// soon as the condition is true, so it is generous enough to ride out a heavily loaded host.
func awaitCondition(
    timeout: TimeInterval = 10,
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

/// Lets the main queue run `turns` rounds of what is already queued, and what that queues in turn.
/// The barrier for "nothing happened": a close that would land, an event that would be delivered, a
/// sheet that would open. It counts main-queue hops, not wall time, so a passing negative check
/// costs microseconds instead of a fixed sleep and a loaded host can't make it shorter. It does
/// not wait out a timer: for work behind a `Timer` or `asyncAfter` (Ghostty's 75 ms title
/// coalescing, say) poll the effect with `awaitCondition`, or sleep at least the timer's period.
@MainActor
func drainMainQueue(turns: Int = 25) async {
    for _ in 0 ..< turns {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}

extension Ghostty.SurfaceConfiguration {
    /// A surface that runs `/bin/cat` instead of the user's login shell. It stays alive reading
    /// its pty and never titles itself, so a test that doesn't assert on a shell's own behaviour
    /// (its prompt, its shell-integration titles, what typed input does) doesn't pay for a login
    /// shell's startup or race its first title.
    static func leoStandIn(command: String = "/bin/cat") -> Self {
        var config = Self()
        config.command = command
        return config
    }
}
