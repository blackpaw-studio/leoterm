import AppKit
import Testing

/// Tests that drive real key status (a palette panel taking key, `NSApp.sendEvent`
/// reaching the key window, a surface drawing focused) need the test host to be
/// the active app. A host started from a shell is not frontmost, and macOS
/// grants activation only while no other app holds the foreground, so on a
/// machine where something else runs windowed (a browser, a game capture) the
/// window never becomes key whatever the test does.
///
/// Such a test takes `.requiresActiveHost`, which skips it visibly when the host
/// can't be activated rather than failing on a precondition it doesn't own. A
/// CI run (`GITHUB_ACTIONS`) never skips: the runner has to be able to activate
/// the host, so a regression there fails the test.
@MainActor
enum LeoTestHostActivation {
    private static let timeout: Duration = .seconds(3)
    private static let retryInterval: Duration = .milliseconds(100)

    static func isAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) async -> Bool {
        guard environment["GITHUB_ACTIONS"] == nil else { return true }
        let deadline = ContinuousClock.now + timeout
        while !NSApp.isActive, ContinuousClock.now < deadline {
            NSApp.activate()
            try? await Task.sleep(for: retryInterval)
        }
        return NSApp.isActive
    }
}

extension Trait where Self == ConditionTrait {
    static var requiresActiveHost: Self {
        enabled("needs the test host to be the active app; another app holds the foreground") {
            await LeoTestHostActivation.isAvailable()
        }
    }
}
