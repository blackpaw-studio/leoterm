import XCTest

/// Push end-to-end in the simulator, in two phases a harness runs around
/// `xcrun simctl push` (a UI test can't seal or send the push itself):
///
///   TEST_RUNNER_LEO_PUSH_PHASE=pair  pairs with the daemon in
///     TEST_RUNNER_LEO_PAIRING_PAYLOAD, allows notifications, waits for
///     TEST_RUNNER_LEO_AGENT and leaves the app in the background. The app
///     runs with -exportPushKey, so the harness can read the push key.
///   TEST_RUNNER_LEO_PUSH_PHASE=tap   writes `push-ready` into
///     TEST_RUNNER_LEO_SCREENSHOTS, waits for the harness's push, taps the
///     banner whose body is TEST_RUNNER_LEO_PUSH_BODY and expects that
///     agent's screen. (Taps on Notification Center rows don't register
///     under XCUITest; banner taps do.) TEST_RUNNER_LEO_PUSH_LAUNCH=warm first starts the
///     app and sends it to the background; cold (the default) makes sure it
///     isn't running, so the tap launches it.
///
/// TEST_RUNNER_LEO_SCREENSHOTS saves the captures as PNGs.
final class LeoPushE2ETests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    func testPairAndAllowNotifications() throws {
        try XCTSkipUnless(environment["LEO_PUSH_PHASE"] == "pair", "Set TEST_RUNNER_LEO_PUSH_PHASE=pair")
        let payload = try XCTUnwrap(environment["LEO_PAIRING_PAYLOAD"])
        let agentName = environment["LEO_AGENT"] ?? "apollo"
        let app = XCUIApplication()
        app.launchArguments = ["-resetForUITests", "-exportPushKey"]
        app.launch()

        app.buttons["Pair a Daemon"].tap()
        let field = app.textViews["pairing.payload"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(payload)
        app.buttons["pairing.pair"].tap()

        // The first pairing is when the app asks (only once per install).
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) {
            capture("push-permission")
            allow.tap()
        }
        XCTAssertTrue(app.cells["agent.\(agentName)"].waitForExistence(timeout: 30), "\(agentName) never appeared")

        app.navigationBars["Agents"].buttons["Settings"].tap()
        let toggle = app.switches["settings.notifications"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        settle()
        capture("push-settings")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()

        XCUIDevice.shared.press(.home)
        settle()
    }

    func testTapNotificationOpensAgent() throws {
        try XCTSkipUnless(environment["LEO_PUSH_PHASE"] == "tap", "Set TEST_RUNNER_LEO_PUSH_PHASE=tap")
        let body = try XCTUnwrap(environment["LEO_PUSH_BODY"])
        let agentName = environment["LEO_AGENT"] ?? "apollo"
        let shotName = environment["LEO_PUSH_SHOT"] ?? "push"
        let app = XCUIApplication()
        if environment["LEO_PUSH_LAUNCH"] == "warm" {
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackgroundSuspended, timeout: 15) || app.state == .runningBackground)
        } else {
            app.terminate()
            XCUIDevice.shared.press(.home)
        }

        // Tell the harness to send the push now, then tap its banner.
        let directory = try XCTUnwrap(environment["LEO_SCREENSHOTS"], "the harness waits for a ready marker there")
        try Data().write(to: URL(fileURLWithPath: directory).appendingPathComponent("push-ready"))
        // Each notification is a button labelled "<title>, <body>, …".
        let notification = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch
        XCTAssertTrue(notification.waitForExistence(timeout: 60), "no banner reading \(body)")
        XCTAssertTrue(notification.label.contains(agentName), "the notification doesn't name \(agentName): \(notification.label)")
        capture("\(shotName)-notification")

        notification.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "Leo didn't open")
        let detail = app.collectionViews["agent.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 30), "the agent screen never opened")
        XCTAssertTrue(app.navigationBars[agentName].waitForExistence(timeout: 5), "opened some other agent")
        settle()
        capture("\(shotName)-agent")
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
