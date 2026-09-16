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
