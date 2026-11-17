import Foundation

/// What the app does at launch depending on who launched it.
enum LaunchPolicy {
    /// Whether launch sends `AppFeature.Action.task`, which loads pairings and
    /// runs the push reconcile. False in the hosted unit-test host, where
    /// those effects would hit unimplemented test dependencies outside any
    /// test and crash the host at random.
    static func startsStoreAtLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }
}
