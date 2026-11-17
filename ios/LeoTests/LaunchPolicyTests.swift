import Testing

@testable import Leo

struct LaunchPolicyTests {
    @Test func theHostedUnitTestHostDoesNotStartTheStore() {
        let environment = ["XCTestConfigurationFilePath": "/tmp/host.xctestconfiguration"]

        #expect(!LaunchPolicy.startsStoreAtLaunch(environment: environment))
    }

    @Test func aNormalLaunchStartsTheStore() {
        #expect(LaunchPolicy.startsStoreAtLaunch(environment: ["HOME": "/var/mobile"]))
    }
}
