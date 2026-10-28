import XCTest

/// B-324: move, copy and duplicate against the scripted `-moveFixture` (no
/// daemon needed). Set `MOVE_SHOTS_DIR` (as `TEST_RUNNER_MOVE_SHOTS_DIR`) to
/// also save each state as `<dir>/ios-<name>.png`.
final class LeoMoveTests: XCTestCase {
    private func launch(hanging: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-moveFixture", "-noAnimationsForUITests"] + (hanging ? ["-moveFixtureHang"] : [])
        app.launch()
        XCTAssertTrue(app.cells["agent.zeus"].waitForExistence(timeout: 10))
        return app
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["MOVE_SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ios-\(name).png"))
        }
    }

    func testTheRowMenuOffersMoveCopyAndDuplicate() {
        let app = launch()
        app.cells["agent.zeus"].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Move To"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy To"].exists)
        XCTAssertTrue(app.buttons["Duplicate…"].exists)
        app.buttons["Move To"].tap()
        XCTAssertTrue(app.buttons["nas"].waitForExistence(timeout: 5))
        shot("context-menu")
    }

    func testAMoveInFlightShowsProgressAndBlocksAnotherRequest() {
        let app = launch(hanging: true)
        app.cells["agent.zeus"].press(forDuration: 1.2)
        app.buttons["Move To"].tap()
        app.buttons["nas"].tap()
        app.buttons["Move"].tap()
        XCTAssertTrue(app.staticTexts["Moving zeus to nas…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["agent.move.hide"].exists)
        shot("in-progress")
        XCTAssertFalse(app.cells["agent.busy-agent"].isHittable, "the progress cover blocks every row, menu and swipe while a move is in flight")
    }

    func testHidingAMoveInFlightGivesTheAppBack() {
        let app = launch(hanging: true)
        app.cells["agent.zeus"].press(forDuration: 1.2)
        app.buttons["Move To"].tap()
        app.buttons["nas"].tap()
        app.buttons["Move"].tap()
        XCTAssertTrue(app.buttons["agent.move.hide"].waitForExistence(timeout: 5))
        app.buttons["agent.move.hide"].tap()
        XCTAssertFalse(app.staticTexts["Moving zeus to nas…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.cells["agent.busy-agent"].isHittable)
    }

    func testAMovedAgentIsADormantRowWithItsDestination() {
        let app = launch()
        let row = app.cells["agent.old-agent"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.staticTexts["Moved to nas · 1 hour ago"].exists)
        shot("moved-row")
        row.tap()
        let detail = app.collectionViews["agent.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        XCTAssertFalse(app.cells["agent.move.duplicate"].exists, "a moved agent can't move again")
        XCTAssertFalse(app.cells["agent.command.start"].exists, "nor be started here")
        shot("moved-detail")
    }

    func testMovingAConfirmedAgentLeavesADormantRow() {
        let app = launch()
        app.cells["agent.zeus"].press(forDuration: 1.2)
        app.buttons["Move To"].tap()
        app.buttons["hestia"].tap()
        XCTAssertTrue(app.staticTexts["Move zeus to hestia?"].waitForExistence(timeout: 5))
        shot("move-confirmation")
        app.buttons["Move"].tap()
        XCTAssertTrue(app.cells["agent.zeus"].staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Moved to hestia'")).firstMatch.waitForExistence(timeout: 10))
    }

    func testABusyAgentOffersMoveAnywayAndThenMoves() {
        let app = launch()
        app.cells["agent.busy-agent"].press(forDuration: 1.2)
        app.buttons["Move To"].tap()
        app.buttons["nas"].tap()
        app.buttons["Move"].tap()
        XCTAssertTrue(app.staticTexts["busy-agent is busy"].waitForExistence(timeout: 10))
        shot("force-prompt")
        app.buttons["Move Anyway"].tap()
        XCTAssertTrue(app.cells["agent.busy-agent"].staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Moved to nas'")).firstMatch.waitForExistence(timeout: 10))
    }

    func testADaemonRefusalShowsItsText() {
        let app = launch()
        app.cells["agent.zeus"].press(forDuration: 1.2)
        app.buttons["Move To"].tap()
        app.buttons["work"].tap()
        app.buttons["Move"].tap()
        XCTAssertTrue(app.staticTexts["work is unreachable over SSH."].waitForExistence(timeout: 10))
        shot("error-alert")
        app.buttons["OK"].tap()
    }

    func testDuplicateAsksForAnOptionalNameThenAddsTheCopy() {
        let app = launch()
        app.cells["agent.zeus"].press(forDuration: 1.2)
        app.buttons["Duplicate…"].tap()
        let field = app.textFields["agent.move.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        shot("name-prompt")
        field.tap()
        field.typeText("twin")
        app.buttons["Copy"].tap()
        XCTAssertTrue(app.cells["agent.twin"].waitForExistence(timeout: 10))
    }

    func testTheSwipeOffersTheSameChoices() {
        let app = launch()
        app.cells["agent.zeus"].swipeLeft()
        XCTAssertTrue(app.buttons["Move"].waitForExistence(timeout: 5))
        shot("swipe")
        app.buttons["Move"].tap()
        XCTAssertTrue(app.buttons["Duplicate…"].waitForExistence(timeout: 5))
    }

    func testTheDetailHasAMoveSection() {
        let app = launch()
        app.cells["agent.zeus"].tap()
        let detail = app.collectionViews["agent.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        // The Move section is below the fold, and off-screen cells don't exist yet.
        let duplicate = app.cells["agent.move.duplicate"]
        for _ in 0..<5 where !duplicate.exists { detail.swipeUp() }
        XCTAssertTrue(duplicate.exists)
        XCTAssertTrue(app.cells["agent.move.to"].exists)
        XCTAssertTrue(app.cells["agent.move.copyTo"].exists)
        shot("detail-move")
        duplicate.tap()
        XCTAssertTrue(app.textFields["agent.move.name"].waitForExistence(timeout: 5))
    }
}
