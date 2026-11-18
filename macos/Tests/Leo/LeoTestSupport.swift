import Foundation
import Testing

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
