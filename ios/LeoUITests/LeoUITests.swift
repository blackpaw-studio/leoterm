import XCTest

/// Smoke test: the app launches into the empty Agents screen.
final class LeoLaunchTests: XCTestCase {
    func testLaunchesIntoAgents() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetForUITests"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 10))
    }
}
