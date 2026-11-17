import ComposableArchitecture
import Testing

@testable import Leo

@MainActor
struct LaunchPolicyTests {
    /// The host app's own store, driven as AppDelegate and SceneDelegate drive
    /// it. Any unimplemented test dependency it reaches records an issue here.
    @Test func hostStoreLifecycleReachesNoUnimplementedDependency() async {
        let store = AppDelegate.store

        await LaunchPolicy.send(.task, to: store)?.finish()
        await LaunchPolicy.send(.scenePhaseChanged(isActive: true), to: store)?.finish()
        await LaunchPolicy.send(.scenePhaseChanged(isActive: false), to: store)?.finish()
    }

    @Test func theHostedUnitTestHostDoesNotStartTheStore() {
        let environment = ["XCTestConfigurationFilePath": "/tmp/host.xctestconfiguration"]

        #expect(!LaunchPolicy.startsStoreAtLaunch(environment: environment))
    }

    @Test func aNormalLaunchStartsTheStore() {
        #expect(LaunchPolicy.startsStoreAtLaunch(environment: ["HOME": "/var/mobile"]))
    }
}
