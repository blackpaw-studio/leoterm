import XCTest

/// Dismissing blocked inbox cards against the scripted `-inboxFixture` (no
/// daemon): the trailing swipe and the Dismiss button. Optional:
/// TEST_RUNNER_LEO_SCREENSHOTS=/path/dir writes each capture as a PNG.
final class LeoInboxDismissTests: XCTestCase {
    private var app: XCUIApplication!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
        app = XCUIApplication()
        app.launchArguments = ["-resetForUITests", "-inboxFixture"]
        app.launch()
        let needsYou = app.buttons["chats.filter.needsYou"]
        XCTAssertTrue(needsYou.waitForExistence(timeout: 15), "the Needs you chip never appeared")
        needsYou.tap()
        XCTAssertTrue(app.cells["inbox.zeus"].waitForExistence(timeout: 10), "zeus's blocked card never appeared")
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    func testSwipingABlockedCardDismissesIt() {
        let zeus = app.cells["inbox.zeus"]
        XCTAssertTrue(zeus.buttons["inbox.dismiss"].exists, "a visible Dismiss button covers accessibility")
        capture("inbox-dismiss-card")
        zeus.swipeLeft(velocity: .slow)
        capture("inbox-dismiss-swipe")
        zeus.swipeLeft()
        XCTAssertTrue(zeus.waitForNonExistence(timeout: 5), "the swiped card never left the inbox")
        XCTAssertTrue(app.cells["inbox.olympus"].exists, "dismissing one card must not touch another")
        capture("inbox-dismiss-after-swipe")
    }

    func testTheDismissButtonDismissesTheCardAndLeavesTheOthers() {
        let olympus = app.cells["inbox.olympus"]
        XCTAssertTrue(olympus.waitForExistence(timeout: 5))
        olympus.buttons["inbox.dismiss"].tap()
        XCTAssertTrue(olympus.waitForNonExistence(timeout: 5), "the Dismiss button never hid the card")
        XCTAssertTrue(app.cells["inbox.zeus"].exists, "dismissing one card must not touch another")
        capture("inbox-dismiss-after-button")
    }

    private func capture(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = environment["LEO_SCREENSHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
