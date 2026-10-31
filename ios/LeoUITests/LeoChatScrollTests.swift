import XCTest

/// Opening a long thread lands on its newest message, and sending keeps it
/// there. Runs against `-navFixture -chatScrollFixture` (agent-0).
final class LeoChatScrollTests: XCTestCase {
    private func openThread() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-navFixture", "-chatScrollFixture", "-noAnimationsForUITests"]
        app.launch()
        let row = app.cells["chat.agent-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 10))
        return app
    }

    override func setUp() { continueAfterFailure = false }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let dir = ProcessInfo.processInfo.environment["TEST_RUNNER_LEO_SCREENSHOTS"] ?? ProcessInfo.processInfo.environment["LEO_SCREENSHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    /// Polls `condition` until it holds or `timeout` passes.
    private func wait(timeout: TimeInterval = 5, until condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The newest bubble's bottom edge is above the composer and on screen.
    private func assertNewestVisible(_ app: XCUIApplication, id: String, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let thread = app.collectionViews["chat.thread"]
        let composer = app.textViews["chat.composer.text"]
        let newest = app.cells["chat.message.\(id)"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5), "\(context): newest cell exists", file: file, line: line)
        // Late self-sizing (an image loading) may still be moving the list.
        _ = wait { newest.frame.maxY <= composer.frame.minY + 20 && newest.frame.maxY >= thread.frame.maxY - 220 }
        XCTAssertTrue(newest.isHittable || newest.frame.maxY <= composer.frame.minY + 1, "\(context): newest cell visible", file: file, line: line)
        XCTAssertLessThanOrEqual(newest.frame.maxY, composer.frame.minY + 20, "\(context): newest cell ends above the composer (maxY \(newest.frame.maxY), composer \(composer.frame.minY))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(newest.frame.maxY, thread.frame.maxY - 220, "\(context): list is not scrolled short of the bottom (maxY \(newest.frame.maxY))", file: file, line: line)
    }

    func testOpensAtTheNewestMessage() {
        let app = openThread()
        snapshot("scroll-open")
        assertNewestVisible(app, id: "s69", "after open")
    }

    /// The keyboard shrinks the list: the newest message rides up with it.
    func testKeyboardKeepsTheNewestMessageInView() {
        let app = openThread()
        app.textViews["chat.composer.text"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        snapshot("scroll-keyboard")
        assertNewestVisible(app, id: "s69", "with the keyboard up")
    }

    /// Scrolled up to read, the list stays put when the keyboard comes up.
    func testReaderScrolledUpIsNotPulledDown() {
        let app = openThread()
        let thread = app.collectionViews["chat.thread"]
        for _ in 0..<3 { thread.swipeDown() }
        let before = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.s")).firstMatch.identifier
        app.textViews["chat.composer.text"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The list has resized above the keyboard: the layout pass a pin would act on.
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(wait { thread.frame.maxY <= keyboard.frame.minY }, "the list never resized above the keyboard")
        XCTAssertFalse(app.cells["chat.message.s69"].isHittable, "a reader scrolled up was pulled to the newest message")
        XCTAssertTrue(app.cells[before].exists, "the reader's place moved")
    }

    /// The status bar tap scrolls to the top, and the list doesn't fight it back down.
    func testStatusBarTapScrollsToTheTopAndStays() {
        let app = openThread()
        // The status bar isn't in the accessibility tree: tap where it is.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).tap()
        XCTAssertTrue(wait { app.cells["chat.message.s20"].isHittable }, "the status bar tap never reached the top")
        XCTAssertFalse(app.cells["chat.message.s69"].isHittable, "the list snapped back to the bottom")
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.s")).firstMatch.exists)
    }

    /// Sending is the reader asking to be at the bottom, wherever they were.
    func testScrolledUpReaderSendsAndSeesTheirMessage() {
        let app = openThread()
        let thread = app.collectionViews["chat.thread"]
        for _ in 0..<3 { thread.swipeDown() }
        let composer = app.textViews["chat.composer.text"]
        composer.tap()
        composer.typeText("sent from up here")
        app.buttons["chat.composer.send"].tap()
        assertNewestVisible(app, id: "zz-sent-1", "after a scrolled-up send")
    }

    func testStaysAtTheBottomAfterSending() {
        let app = openThread()
        assertNewestVisible(app, id: "s69", "after open")
        let composer = app.textViews["chat.composer.text"]
        composer.tap()
        composer.typeText("one\ntwo\nthree")
        snapshot("scroll-typed")
        app.buttons["chat.composer.send"].tap()
        assertNewestVisible(app, id: "zz-sent-1", "after send")
        snapshot("scroll-sent")
        composer.typeText("again")
        app.buttons["chat.composer.send"].tap()
        assertNewestVisible(app, id: "zz-sent-2", "after second send")
    }
}
