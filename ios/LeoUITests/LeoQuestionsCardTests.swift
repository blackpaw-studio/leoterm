import XCTest

/// The AskUserQuestion card against the app's DEBUG fixture thread
/// (`-questionsCardFixture <state>`, a scripted chat client; no daemon).
/// Optional: TEST_RUNNER_LEO_SCREENSHOTS=/path/dir writes each state's
/// light and dark capture as `questions-<state>-<appearance>.png`.
final class LeoQuestionsCardTests: XCTestCase {
    /// Mirrors `ChatQuestionsFixture.stateNames`.
    private static let states = ["open", "partial", "filled", "refused", "sending", "answered", "terminal", "dismissed", "timedout"]

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    private func launch(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetForUITests", "-questionsCardFixture", fixture]
        app.launch()
        return app
    }

    func testEveryStateInLightAndDark() {
        for state in Self.states {
            let app = launch(state)
            XCTAssertTrue(app.cells["chat.message.card-\(state)"].waitForExistence(timeout: 10), "\(state) card never appeared")
            let card = app.cells["chat.message.card-\(state)"]
            switch state {
            case "open", "partial", "filled", "refused", "sending":
                XCTAssertTrue(card.buttons["chat.questions.dismiss"].exists, "\(state): no Answer in terminal")
                let submit = card.buttons["chat.questions.submit"]
                XCTAssertTrue(submit.exists, "\(state): no Submit")
                // Only a complete draft, with nothing in flight, can submit.
                XCTAssertEqual(submit.isEnabled, state == "filled" || state == "refused", "\(state): Submit enabled?")
            case "answered":
                XCTAssertTrue(card.staticTexts["Library: Swift"].exists)
                XCTAssertTrue(card.staticTexts["Scope: Lexer, Parser, \"and the CLI\""].exists)
            case "terminal", "dismissed":
                XCTAssertTrue(card.staticTexts["Answered in terminal"].exists)
            default:
                XCTAssertTrue(card.staticTexts["Timed out"].exists)
            }
            captureBothAppearances("questions-\(state)")
            app.terminate()
        }
    }

    /// The full-size card is taller than the screen: capture its top and bottom.
    func testALongCardScrolls() {
        let app = launch("long")
        let thread = app.collectionViews["chat.thread"]
        let card = app.cells["chat.message.card-long"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        for _ in 0..<3 { thread.swipeDown() }
        captureBothAppearances("questions-long-top")
        for _ in 0..<3 { thread.swipeUp() }
        captureBothAppearances("questions-long-bottom")
    }

    func testChoicesAndTypedTextSurviveCellReuseAndSubmit() {
        let app = launch("all")
        let thread = app.collectionViews["chat.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        let card = app.cells["chat.message.card-open"]
        scroll(to: card, in: thread, up: false)

        card.buttons["chat.questions.q1.option.Zig"].tap()
        XCTAssertTrue(card.buttons["chat.questions.q1.option.Zig"].isSelected)
        XCTAssertFalse(card.buttons["chat.questions.q1.option.Swift"].isSelected)
        card.buttons["chat.questions.q2.option.Lexer"].tap()
        let other = card.textViews["chat.questions.q2.text"]
        other.tap()
        other.typeText("typed text")
        waitForValue("typed text", of: other)

        // Far enough away that the cell is recycled, then back.
        scroll(to: app.cells["chat.message.filler-13"], in: thread, up: true)
        scroll(to: card, in: thread, up: false)
        waitForValue("typed text", of: card.textViews["chat.questions.q2.text"], "the draft text was lost with the cell")
        XCTAssertTrue(card.buttons["chat.questions.q1.option.Zig"].isSelected, "the choice was lost with the cell")
        XCTAssertTrue(card.buttons["chat.questions.q2.option.Lexer"].isSelected)

        let submit = card.buttons["chat.questions.submit"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        // The settled card is much shorter, so the thread may leave it above the screen.
        scroll(to: card, in: thread, up: false)
        XCTAssertTrue(card.staticTexts["Library: Zig"].waitForExistence(timeout: 10), "the card never settled")
        XCTAssertTrue(card.staticTexts["Scope: Lexer, \"typed text\""].exists)
        XCTAssertFalse(submit.exists)
    }

    func testAnswerInTerminalSettlesTheCard() {
        let app = launch("open")
        let card = app.cells["chat.message.card-open"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.buttons["chat.questions.dismiss"].tap()
        XCTAssertTrue(card.staticTexts["Answered in terminal"].waitForExistence(timeout: 5))
    }

    /// Typing lands on the main thread a beat after `typeText` returns.
    private func waitForValue(_ value: String, of element: XCUIElement, _ message: String = "") {
        let matches = NSPredicate(format: "value == %@", value)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: matches, object: element)], timeout: 5)
        XCTAssertEqual(result, .completed, "\(message) (value: \(element.value as? String ?? "nil"))")
    }

    /// Swipes `thread` until `element` is on screen; `up` scrolls toward the
    /// newest messages.
    private func scroll(to element: XCUIElement, in thread: XCUIElement, up: Bool) {
        for _ in 0..<30 where !(element.exists && element.isHittable) {
            if up { thread.swipeUp() } else { thread.swipeDown() }
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) never scrolled into view")
    }

    private func captureBothAppearances(_ name: String) {
        XCUIDevice.shared.appearance = .light
        settle()
        capture("\(name)-light")
        XCUIDevice.shared.appearance = .dark
        settle()
        capture("\(name)-dark")
        XCUIDevice.shared.appearance = .light
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private func capture(_ name: String) {
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
