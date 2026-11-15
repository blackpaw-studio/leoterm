import XCTest

/// The native Markdown viewer, against `-navFixture -chatMarkdownFixture`:
/// agent-0 has a message with `sample.md` and `notes.txt`.
final class LeoChatMarkdownViewerTests: XCTestCase {
    private func openThread() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-navFixture", "-chatMarkdownFixture", "-noAnimationsForUITests"]
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

    /// The first tap on a file starts its download; once it is on disk a tap opens it.
    private func openFile(_ app: XCUIApplication, _ id: String, opens opened: () -> XCUIElement) {
        let chip = element(app, "chat.file.\(id)")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "\(id) chip exists")
        for _ in 0..<5 where !opened().exists {
            chip.tap()
            _ = opened().waitForExistence(timeout: 2)
        }
    }

    func testRendersTogglesToRawAndScrollsAWideTable() {
        let app = openThread()
        openFile(app, "sample") { app.segmentedControls["markdown.mode"] }
        XCTAssertTrue(app.segmentedControls["markdown.mode"].exists, "mode toggle")
        XCTAssertTrue(app.textViews["Release notes"].waitForExistence(timeout: 5), "h1 renders")
        XCTAssertTrue(element(app, "markdown.rendered").exists)
        snapshot("md-rendered")

        let table = element(app, "markdown.table")
        let rendered = element(app, "markdown.rendered")
        for _ in 0..<6 where !table.isHittable { rendered.swipeUp() }
        XCTAssertTrue(table.isHittable, "table scrolled into view")
        table.swipeLeft()
        snapshot("md-table-scrolled")

        app.segmentedControls["markdown.mode"].buttons["Raw"].tap()
        XCTAssertTrue(element(app, "markdown.raw").waitForExistence(timeout: 5), "raw view")
        snapshot("md-raw")
    }

    func testPlainTextStaysInQuickLook() {
        let app = openThread()
        let chip = element(app, "chat.file.notes")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "notes chip exists")
        // The first tap downloads; once on disk a tap opens QuickLook over the thread.
        for _ in 0..<5 where chip.isHittable {
            chip.tap()
            sleep(2)
        }
        XCTAssertFalse(chip.isHittable, "a viewer opened over the thread")
        XCTAssertFalse(app.segmentedControls["markdown.mode"].exists)
    }
}
