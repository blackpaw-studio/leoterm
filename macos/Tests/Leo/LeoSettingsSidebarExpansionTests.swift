import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor
struct LeoSettingsSidebarExpansionTests {
    @Test func openingAMachineAfterAnAppPageCollapsesTheMachineShownBefore() throws {
        let harness = try LeoSettingsSidebarModelTests.harness()
        let dionysus = LeoSettingsMachineRef.remote(LeoSettingsSidebarModelTests.dionysus.id)

        harness.sidebar.select(.general)
        harness.sidebar.select(.machine(dionysus))

        #expect(harness.sidebar.expanded == [dionysus])
    }

    @Test func returningToAMachineFromAnAppPageExpandsItAgain() throws {
        let harness = try LeoSettingsSidebarModelTests.harness()
        harness.sidebar.toggleDisclosure(.local)
        harness.sidebar.select(.general)
        harness.sidebar.select(.machine(.local))

        #expect(harness.sidebar.expanded == [.local])
    }
}
