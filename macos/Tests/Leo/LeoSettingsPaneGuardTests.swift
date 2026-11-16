import Testing

@testable import Ghostty
@testable import LeoKit

/// A pane row that is disabled must not be selectable: the keyboard and
/// macOS 13's List can still land on it.
@MainActor
struct LeoSettingsPaneGuardTests {
    @Test func anUnsavedMachinesPanesCannotBeSelected() throws {
        let harness = try LeoSettingsSidebarModelTests.harness()
        harness.sidebar.addMachine()
        let added = try #require(harness.model.hosts.last)
        let ref = LeoSettingsMachineRef.remote(added.id)

        harness.sidebar.select(.pane(ref, .tasks))

        #expect(harness.sidebar.selection == .machine(ref))
        #expect(harness.sidebar.rows.last?.panesEnabled == false)
    }

    @Test func aMachineTurnedOffCannotHaveItsPanesSelected() throws {
        let harness = try LeoSettingsSidebarModelTests.harness()
        let hestia = LeoSettingsMachineRef.remote(LeoSettingsSidebarModelTests.hestia.id)

        harness.sidebar.select(.pane(hestia, .tasks))

        #expect(harness.sidebar.selection == .machine(.local))
    }

    @Test func aConnectedMachinesPanesCanBeSelected() throws {
        let harness = try LeoSettingsSidebarModelTests.harness()
        let dionysus = LeoSettingsMachineRef.remote(LeoSettingsSidebarModelTests.dionysus.id)

        harness.sidebar.select(.pane(dionysus, .tasks))

        #expect(harness.sidebar.selection == .pane(dionysus, .tasks))
    }

    @Test func openingAPaneOfAMachineWithoutPanesLandsOnItsOverview() throws {
        let harness = try LeoSettingsSidebarModelTests.harness()
        let hestia = LeoSettingsMachineRef.remote(LeoSettingsSidebarModelTests.hestia.id)

        harness.sidebar.open(.pane(hestia, .appearance))

        #expect(harness.sidebar.selection == .machine(hestia))
    }
}
