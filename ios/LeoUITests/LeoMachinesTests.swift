import XCTest

/// The Machines list and its Stats style setting, against the scripted
/// `-machinesFixture` machines (no daemon needed). The fixture replaces the
/// paired-daemon store, so it must not be combined with `-resetForUITests`,
/// which would touch the real one first.
final class LeoMachinesTests: XCTestCase {
    func testStatsStyleChoiceFromSettingsAppliesToTheMachinesList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-machinesFixture", "-statsStyle", "capsules"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["daemon.Dionysus"].waitForExistence(timeout: 10))
        // Capsules: the meter line reads as one element with all three values.
        XCTAssertTrue(app.otherElements["CPU 23%, Memory 85%, Disk 47%"].waitForExistence(timeout: 10))
        attach(app, "machines-capsules")

        app.navigationBars["Machines"].buttons.element(boundBy: 0).tap()
        app.navigationBars["Agents"].buttons["Settings"].tap()
        app.cells["settings.statsStyleRow"].tap()
        attach(app, "stats-style")
        app.cells["settings.statsStyle.numbers"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars["Agents"].buttons["Machines"].tap()
        XCTAssertTrue(app.otherElements["CPU 23%, Memory 85%, Disk 47%"].waitForExistence(timeout: 10))
        attach(app, "machines-numbers")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
