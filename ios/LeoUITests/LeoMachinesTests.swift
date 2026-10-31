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

        app.tabBars.buttons["Settings"].tap()
        app.cells["settings.statsStyleRow"].tap()
        attach(app, "stats-style")
        app.cells["settings.statsStyle.numbers"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Machines"].tap()
        XCTAssertTrue(app.otherElements["CPU 23%, Memory 85%, Disk 47%"].waitForExistence(timeout: 10))
        attach(app, "machines-numbers")
    }

    /// Settings > Chat: the live terminal default starts on "While working",
    /// switches to "Always" from the pop-up menu, and is put back so a rerun
    /// starts from the same place.
    func testLiveTerminalModeMenuChangesFromSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-machinesFixture", "-statsStyle", "capsules"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let row = app.cells["settings.liveTerminal"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.staticTexts["While working"].exists)
        attach(app, "settings-live-terminal")
        row.tap()
        app.buttons["Always"].tap()
        XCTAssertTrue(row.staticTexts["Always"].waitForExistence(timeout: 5))
        row.tap()
        app.buttons["While working"].tap()
        XCTAssertTrue(row.staticTexts["While working"].waitForExistence(timeout: 5))
    }

    /// Back from an open machine returns to the Machines list, whose rows
    /// must still open a machine.
    func testMachinesListStaysUsableAfterBackFromAMachine() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-machinesFixture", "-statsStyle", "capsules"]
        app.launch()
        let row = app.cells["daemon.Dionysus"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Dionysus"].waitForExistence(timeout: 5))
        app.navigationBars["Dionysus"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Dionysus"].waitForExistence(timeout: 5))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
