import XCTest

/// The full-screen image viewer, against `-navFixture -chatImagesFixture`:
/// agent-0 has a message of four images (pic-1…pic-4) and one of a single image.
final class LeoChatImageViewerTests: XCTestCase {
    private func openThread() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-navFixture", "-chatImagesFixture", "-noAnimationsForUITests"]
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
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func position(_ app: XCUIApplication) -> XCUIElement { element(app, "chat.imageViewer.position") }

    private func assertPosition(_ app: XCUIApplication, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let label = position(app)
        XCTAssertTrue(label.waitForExistence(timeout: 5), "position label exists", file: file, line: line)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: label)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed, "position reads \(text), is \(label.label)", file: file, line: line)
    }

    private func openViewer(_ app: XCUIApplication, imageID: String) {
        let image = element(app, "chat.image.\(imageID)")
        XCTAssertTrue(image.waitForExistence(timeout: 10), "\(imageID) loads inline")
        // The thread rests on its newest message; the four-image message may sit above the fold.
        let thread = app.collectionViews["chat.thread"]
        for _ in 0..<6 where !image.isHittable { thread.swipeDown() }
        XCTAssertTrue(image.isHittable, "\(imageID) is on screen")
        image.tap()
    }

    func testPagesThroughAMessagesImages() {
        let app = openThread()
        openViewer(app, imageID: "pic-2")
        assertPosition(app, "2 of 4")
        XCTAssertTrue(element(app, "chat.imageViewer.image.pic-2").waitForExistence(timeout: 5))
        snapshot("viewer-2-of-4")

        app.swipeLeft()
        assertPosition(app, "3 of 4")
        XCTAssertTrue(element(app, "chat.imageViewer.image.pic-3").waitForExistence(timeout: 5))
        snapshot("viewer-3-of-4-tall")

        app.swipeRight()
        app.swipeRight()
        assertPosition(app, "1 of 4")
        app.swipeRight()
        assertPosition(app, "1 of 4")
        snapshot("viewer-1-of-4")

        element(app, "chat.imageViewer.close").tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: position(app))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "viewer closes")
        snapshot("viewer-closed-thread")
    }

    func testSingleImageHasNoPagingAndSwipesDownToClose() {
        let app = openThread()
        openViewer(app, imageID: "pic-solo")
        let close = element(app, "chat.imageViewer.close")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "chat.imageViewer.image.pic-solo").waitForExistence(timeout: 5))
        XCTAssertFalse(position(app).isHittable, "a single image shows no position")
        snapshot("viewer-single")

        app.swipeLeft()
        XCTAssertTrue(element(app, "chat.imageViewer.image.pic-solo").exists, "a left swipe doesn't page")

        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)), withVelocity: .fast, thenHoldForDuration: 0)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "swipe down closes the viewer")
    }
}
