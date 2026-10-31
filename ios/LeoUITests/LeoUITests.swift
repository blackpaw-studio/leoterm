import XCTest

/// Smoke test: the app launches into the empty Chats inbox, with the tab bar.
final class LeoLaunchTests: XCTestCase {
    func testLaunchesIntoChats() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetForUITests"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        for tab in ["Chats", "Agents", "Machines", "Settings"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists, "\(tab) tab")
        }
    }
}
