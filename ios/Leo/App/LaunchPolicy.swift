import ComposableArchitecture
import Foundation
import LeoFeatures

/// What the app does at launch and on scene changes depending on who launched it.
enum LaunchPolicy {
    /// Whether the app drives its store from the launch and scene lifecycle.
    /// False in the hosted unit-test host: the lifecycle effects (pairings
    /// load, push reconcile on activation) would hit unimplemented test
    /// dependencies outside any test and crash the host at random.
    ///
    /// Relies on `XCTestConfigurationFilePath` being set in the hosted
    /// unit-test host and not inherited by `XCUIApplication` launches, so UI
    /// tests keep the full lifecycle.
    static func startsStoreAtLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    /// Sends a launch or scene-lifecycle action, unless `startsStoreAtLaunch` says not to.
    @MainActor @discardableResult
    static func send(
        _ action: AppFeature.Action,
        to store: StoreOf<AppFeature>,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> StoreTask? {
        guard startsStoreAtLaunch(environment: environment) else { return nil }
        return store.send(action)
    }
}
