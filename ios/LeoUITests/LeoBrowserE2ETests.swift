import XCTest

/// B-305 end to end against a scratch daemon: pair by pasting its `leo pair`
/// payload, open the agent's Browser pane, and play the user's side while a
/// harness makes the agent's browser calls over the daemon's client-tools
/// relay. The harness ends with `browser_handoff`; this answers it with
/// Done, then types a localhost address to see the pane's explanation.
/// Skipped unless the runner passes the payload:
///   TEST_RUNNER_LEO_BROWSER_PAIRING_PAYLOAD='{"daemon_id":…}'
///   TEST_RUNNER_LEO_AGENT=autopilot-scratch
///   TEST_RUNNER_LEO_SCREENSHOTS=/path/dir   (optional)
/// Never point it at a real daemon: it answers the agent's handoff.
final class LeoBrowserE2ETests: XCTestCase {
    private var app: XCUIApplication!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(environment["LEO_BROWSER_PAIRING_PAYLOAD"] == nil, "No pairing payload; set TEST_RUNNER_LEO_BROWSER_PAIRING_PAYLOAD")
        app = XCUIApplication()
        app.launchArguments = ["-resetForUITests"]
        app.launch()
    }

    func testAnAgentDrivesTheBrowserOnThisIPhone() throws {
        let payload = try XCTUnwrap(environment["LEO_BROWSER_PAIRING_PAYLOAD"])
        let agentName = environment["LEO_AGENT"] ?? "autopilot-scratch"

        app.tabBars.buttons["Agents"].tap()
        app.buttons["Pair a Daemon"].tap()
        let field = app.textViews["pairing.payload"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(payload)
        app.buttons["pairing.pair"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 20), "pairing never finished")

        let row = app.cells["agent.\(agentName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "\(agentName) never appeared")
        row.tap()
        let browserRow = app.cells["agent.browser"]
        XCTAssertTrue(browserRow.waitForExistence(timeout: 20), "the Browser row never showed (client_tools not advertised?)")
        browserRow.tap()
        let address = app.textFields["browser.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))

        // The harness drives the agent's calls; its last is a handoff.
        let done = app.buttons["browser.handoff.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 300), "the agent's handoff never reached the pane")
        settle()
        capture("handoff")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10))

        address.tap()
        address.typeText("localhost:5173\n")
        // The typed address replaces the page's, so the pane explains localhost.
        let explanation = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "localhost, which Leo on iPhone can't reach")).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 10), "no explanation for localhost")
        settle()
        capture("localhost")
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
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
