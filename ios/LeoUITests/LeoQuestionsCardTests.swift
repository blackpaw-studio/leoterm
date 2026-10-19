import XCTest

/// The AskUserQuestion card against the app's DEBUG fixture thread
/// (`-questionsCardFixture <state>`, a scripted chat client; no daemon).
/// Optional: TEST_RUNNER_LEO_SCREENSHOTS=/path/dir writes each state's
/// light and dark capture as `questions-<state>-<appearance>.png`.
final class LeoQuestionsCardTests: XCTestCase {
    /// Mirrors `ChatQuestionsFixture.stateNames`.
    private static let states = [
        "open", "partial", "filled", "refused", "sending", "answered", "terminal", "dismissed", "timedout"
    ]

    private var app: XCUIApplication!
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
        let launched = XCUIApplication()
        launched.launchArguments = ["-resetForUITests", "-questionsCardFixture", fixture]
        launched.launch()
        app = launched
        return launched
    }

    func testEveryStateInLightAndDark() {
        for state in Self.states {
            let app = launch(state)
            let card = app.cells["chat.message.card-\(state)"]
            XCTAssertTrue(card.waitForExistence(timeout: 10), "\(state) card never appeared")
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

    /// The open card sits last; its cell is recycled for the others while the
    /// thread scrolls up, and nothing typed in it may leak into them.
    func testChoicesAndTypedTextSurviveCellReuseAndSubmit() {
        let app = launch("reuse")
        let thread = app.collectionViews["chat.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        let card = app.cells["chat.message.card-open"]
        let first = app.cells["chat.message.card-filled"]
        let middle = app.cells["chat.message.card-partial"]

        card.buttons["chat.questions.q1.option.Zig"].tap()
        XCTAssertTrue(card.buttons["chat.questions.q1.option.Zig"].isSelected)
        XCTAssertFalse(card.buttons["chat.questions.q1.option.Swift"].isSelected)
        card.buttons["chat.questions.q2.option.Lexer"].tap()
        let other = card.textViews["chat.questions.q2.text"]
        other.tap()
        other.typeText("typed text")
        waitForValue("typed text", of: other)
        // Choosing an option ends editing, which lowers the keyboard.
        card.buttons["chat.questions.q2.option.Parser"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard stayed up")

        scroll(to: first.textViews["chat.questions.q2.text"], in: thread, toNewest: false)
        waitForValue("and the CLI", of: first.textViews["chat.questions.q2.text"], "the typed text leaked")
        XCTAssertTrue(first.buttons["chat.questions.q1.option.Swift"].isSelected)
        XCTAssertFalse(first.buttons["chat.questions.q1.option.Zig"].isSelected)

        scroll(to: card.buttons["chat.questions.submit"], in: thread, toNewest: true)
        waitForValue("typed text", of: card.textViews["chat.questions.q2.text"], "the draft text was lost")
        XCTAssertTrue(card.buttons["chat.questions.q1.option.Zig"].isSelected, "the choice was lost with the cell")
        XCTAssertTrue(card.buttons["chat.questions.q2.option.Lexer"].isSelected)
        XCTAssertTrue(card.buttons["chat.questions.q2.option.Parser"].isSelected)

        XCTAssertTrue(card.buttons["chat.questions.submit"].isEnabled)
        card.buttons["chat.questions.submit"].tap()
        XCTAssertTrue(card.staticTexts["Library: Zig"].waitForExistence(timeout: 10), "the card never settled")
        XCTAssertTrue(card.staticTexts["Scope: Lexer, Parser, \"typed text\""].exists)
        XCTAssertFalse(card.buttons["chat.questions.submit"].exists)
    }

    /// A tall card settling is far shorter; the thread must not be left past it.
    func testASubmittedCardStaysOnScreen() {
        let settled = revealSettling("chat.questions.submit")
        let summary = settled.staticTexts["Library: Swift"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "the card never settled")
        XCTAssertTrue(summary.isHittable, "the settled card is off screen")
        capture("questions-settled-after-submit")
    }

    func testADismissedCardStaysOnScreen() {
        let settled = revealSettling("chat.questions.dismiss")
        let outcome = settled.staticTexts["Answered in terminal"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 10), "the card never settled")
        XCTAssertTrue(outcome.isHittable, "the dismissed card is off screen")
        capture("questions-settled-after-dismiss")
    }

    /// A card timing out above the screen is not the user's doing: the thread stays where they are.
    func testAnUnsolicitedSettleDoesNotScrollTheThread() {
        let app = launch("yank")
        let thread = app.collectionViews["chat.thread"]
        let reading = app.cells["chat.message.card-partial"].buttons["chat.questions.dismiss"]
        XCTAssertTrue(reading.waitForExistence(timeout: 10))
        // Let the first layout pass finish before asking where things are.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        scroll(to: reading, in: thread, toNewest: true)

        // The first card, far above, times out on its own.
        app.buttons["yank.timeout"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(reading.isHittable, "the thread scrolled away from what the user was reading")

        let timedOut = app.cells["chat.message.card-open"].staticTexts["Timed out"]
        scroll(to: timedOut, in: thread, toNewest: false)
        XCTAssertTrue(timedOut.isHittable, "the first card never timed out")
    }

    /// Scrolls the first of two tall cards to its footer and taps `button`; returns that card's cell.
    private func revealSettling(_ button: String) -> XCUIElement {
        let app = launch("reveal")
        let thread = app.collectionViews["chat.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        let card = app.cells["chat.message.card-open"]
        scroll(to: card.buttons[button], in: thread, toNewest: false)
        card.buttons[button].tap()
        return card
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

    /// Drags `thread` until `element` is on screen. Without the element in
    /// the hierarchy yet, `toNewest` picks the direction; once it is, which
    /// side of the thread it sits on does. The drag stays between the
    /// navigation bar and a raised keyboard.
    private func scroll(to element: XCUIElement, in thread: XCUIElement, toNewest: Bool) {
        var towardNewest = toNewest
        for _ in 0..<12 where !(element.exists && element.isHittable) {
            if element.exists { towardNewest = element.frame.minY > thread.frame.midY }
            let high = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let lowest = app.keyboards.count > 0 ? 0.5 : 0.8
            let low = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: lowest))
            (towardNewest ? low : high).press(
                forDuration: 0.05, thenDragTo: towardNewest ? high : low, withVelocity: .fast, thenHoldForDuration: 0
            )
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
        let file = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: file)
    }
}
