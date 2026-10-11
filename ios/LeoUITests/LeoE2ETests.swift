import XCTest

/// End-to-end against a real daemon: pair by pasting the `leo pair`
/// payload, watch an agent appear live, stop it. Skipped unless the runner
/// passes the payload, e.g.
///   TEST_RUNNER_LEO_PAIRING_PAYLOAD='{"daemon_id":…}'
///   TEST_RUNNER_LEO_AGENT=apollo            (spawned by the harness after pairing)
///   TEST_RUNNER_LEO_SCREENSHOTS=/path/dir   (optional: light + dark captures)
/// `testTerminalAndSurfacedFiles` expects the agent already running with a
/// PNG and a Markdown file (surfaced with a line) before the app pairs:
///   TEST_RUNNER_LEO_MARKDOWN=notes.md TEST_RUNNER_LEO_PNG=shot.png
final class LeoE2ETests: XCTestCase {
    private var app: XCUIApplication!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(environment["LEO_PAIRING_PAYLOAD"] == nil, "No pairing payload; set TEST_RUNNER_LEO_PAIRING_PAYLOAD")
        XCUIDevice.shared.appearance = .light
        app = XCUIApplication()
        app.launchArguments = ["-resetForUITests"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    func testPairWatchAndStopAnAgent() throws {
        let payload = try XCTUnwrap(environment["LEO_PAIRING_PAYLOAD"])
        let agentName = environment["LEO_AGENT"] ?? "apollo"

        // Pair by pasting.
        app.buttons["Pair a Daemon"].tap()
        let field = app.textViews["pairing.payload"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(payload)
        capture("pairing")
        app.buttons["pairing.pair"].tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 20), "daemon never connected")

        // The harness spawns the agent once the device is paired; it must
        // appear without any refresh.
        let row = app.cells["agent.\(agentName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 120), "\(agentName) never appeared live")
        captureBothAppearances("agents")

        // Daemons screen.
        app.navigationBars["Agents"].buttons["Daemons"].tap()
        XCTAssertTrue(app.navigationBars["Daemons"].waitForExistence(timeout: 5))
        captureBothAppearances("daemons")
        app.navigationBars["Daemons"].buttons.element(boundBy: 0).tap()

        // Agent screen, then stop it with confirmation.
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.collectionViews["agent.detail"].waitForExistence(timeout: 10))
        captureBothAppearances("agent")
        let stop = app.cells["agent.command.stop"]
        scroll(to: stop, in: app.collectionViews["agent.detail"])
        stop.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Stop' AND elementType == %d", XCUIElement.ElementType.button.rawValue)).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no stop confirmation")
        capture("agent-stop-confirm")
        confirm.tap()
        let start = app.cells["agent.command.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 30), "agent never reported stopped")
        app.collectionViews["agent.detail"].swipeDown()
        XCTAssertTrue(app.staticTexts["Stopped"].firstMatch.exists)
        capture("agent-stopped")
    }

    func testTerminalAndSurfacedFiles() throws {
        let payload = try XCTUnwrap(environment["LEO_PAIRING_PAYLOAD"])
        let markdown = try XCTUnwrap(environment["LEO_MARKDOWN"], "set TEST_RUNNER_LEO_MARKDOWN")
        let png = try XCTUnwrap(environment["LEO_PNG"], "set TEST_RUNNER_LEO_PNG")
        let agentName = environment["LEO_AGENT"] ?? "apollo"

        app.buttons["Pair a Daemon"].tap()
        let field = app.textViews["pairing.payload"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(payload)
        app.buttons["pairing.pair"].tap()
        let row = app.cells["agent.\(agentName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(agentName) never appeared")
        row.tap()
        let detail = app.collectionViews["agent.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        XCTAssertTrue(detail.cells["agent.files"].staticTexts["2 surfaced · 2 new"].waitForExistence(timeout: 10), "files row never showed the two new files")

        // Terminal: live, and the screen keeps changing (the agent ticks).
        detail.cells["agent.terminal"].tap()
        let live = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Live'")).firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 20), "terminal never went live")
        let screen = app.descendants(matching: .any)["terminal.screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        settle()
        let before = screen.screenshot().pngRepresentation
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        XCTAssertNotEqual(before, screen.screenshot().pngRepresentation, "terminal output isn't streaming")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard appeared")
        screen.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1), "tapping the terminal raised the keyboard")
        captureBothAppearances("terminal")
        goBack()

        // Files: newest first, both unread.
        detail.cells["agent.files"].tap()
        let list = app.collectionViews["files.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let markdownRow = list.descendants(matching: .any)["file.\(markdown)"]
        let pngRow = list.descendants(matching: .any)["file.\(png)"]
        XCTAssertTrue(markdownRow.waitForExistence(timeout: 5))
        XCTAssertTrue(pngRow.exists)
        XCTAssertLessThan(markdownRow.frame.minY, pngRow.frame.minY, "newest file isn't first")
        XCTAssertEqual(markdownRow.value as? String, "Unread")
        captureBothAppearances("files")

        // Markdown at its line.
        markdownRow.tap()
        let text = app.textViews["file.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 15), "markdown never opened")
        settle()
        captureBothAppearances("markdown-line")
        goBack()
        XCTAssertTrue(markdownRow.waitForExistence(timeout: 5))
        XCTAssertNotEqual(markdownRow.value as? String, "Unread", "opening didn't mark it read")

        // PNG in QuickLook.
        pngRow.tap()
        XCTAssertTrue(app.navigationBars[png].waitForExistence(timeout: 15) || app.staticTexts[png].waitForExistence(timeout: 1), "QuickLook never opened")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        captureBothAppearances("quicklook-png")
        goBack()
        XCTAssertTrue(list.waitForExistence(timeout: 5))
    }

    private func goBack() {
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        settle()
    }

    private func scroll(to element: XCUIElement, in container: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            container.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) not found")
    }

    private func captureBothAppearances(_ name: String) {
        XCUIDevice.shared.appearance = .light
        settle()
        capture("\(name)-light")
        XCUIDevice.shared.appearance = .dark
        settle()
        capture("\(name)-dark")
        XCUIDevice.shared.appearance = .light
        settle()
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = environment["LEO_SCREENSHOTS"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
