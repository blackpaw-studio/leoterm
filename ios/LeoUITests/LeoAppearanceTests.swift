import XCTest

/// Long press on an agent row offers Appearance, and a pick in the sheet
/// updates its source line, against the scripted `-appearanceFixture` (no daemon needed).
final class LeoAppearanceTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appearanceFixture", "-noAnimationsForUITests"]
        app.launch()
        XCTAssertTrue(app.cells["agent.apollo"].waitForExistence(timeout: 10))
        return app
    }

    func testLongPressOpensTheSheetAndAColorPickIsManual() throws {
        let app = launch()
        app.cells["agent.apollo"].press(forDuration: 1.2)
        let item = app.buttons["Appearance…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the context menu offers Appearance")
        item.tap()

        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No color"].exists, "apollo has no color yet")
        app.cells.matching(NSPredicate(format: "label == %@", "Red")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Red, set on this agent"].waitForExistence(timeout: 5))
    }

    func testChatsRowLongPressOffersAppearance() throws {
        let app = launch()
        app.tabBars.buttons["Chats"].tap()
        let all = app.buttons["chats.filter.all"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        let row = app.cells["chat.apollo"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Appearance…"].waitForExistence(timeout: 5), "the Chats row offers the same menu")
    }
}
