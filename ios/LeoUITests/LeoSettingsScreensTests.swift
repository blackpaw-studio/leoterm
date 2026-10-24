import UIKit
import XCTest

/// The machine settings screens against the app's DEBUG fixture machines
/// (`-settingsFixture`, an in-memory daemon; no network). Each state is
/// captured in light and dark as `<name>-light.png` / `<name>-dark.png`.
/// Optional: TEST_RUNNER_LEO_SCREENSHOTS=/path/dir writes the PNGs at 1x.
/// The fixture replaces the paired-daemon store, so there is no
/// `-resetForUITests` here.
final class LeoSettingsScreensTests: XCTestCase {
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

    // MARK: screens

    func testMachineAndItsLists() {
        openMachine("Dionysus")
        capture("machine-detail")

        for list in ["templates", "environments", "tasks"] {
            app.cells["machine.config.\(list)"].tap()
            XCTAssertTrue(app.cells.matching(identifier: "\(list == "tasks" ? "tasks" : "config").row.\(first(of: list))").firstMatch.waitForExistence(timeout: 10), "\(list) never loaded")
            capture("list-\(list)")
            backOut()
        }
    }

    func testOldMachineShowsWhatItRequires() {
        openMachine("leo-vm")
        XCTAssertTrue(app.cells["machine.config.requires"].waitForExistence(timeout: 10))
        capture("machine-requires")
    }

    func testTemplateFormWithEveryFieldType() {
        openTemplate("coder")
        for page in 1...5 {
            capture("template-form-\(page)")
            scrollForm()
        }
    }

    func testDirtyTemplateOffersSave() {
        openTemplate("coder")
        editModel()
        XCTAssertTrue(app.buttons["config.save"].waitForExistence(timeout: 5))
        capture("template-dirty")
    }

    func testStaleSaveShowsTheConflictBanner() {
        openTemplate("coder", arguments: ["-settingsFixtureWrite", "conflict"])
        editModel()
        app.buttons["config.save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'config.banner.'")).firstMatch.waitForExistence(timeout: 10))
        capture("template-conflict")
    }

    func testRejectedValueShowsItsInlineError() {
        openTemplate("coder", arguments: ["-settingsFixtureWrite", "invalid"])
        editModel()
        app.buttons["config.save"].tap()
        XCTAssertTrue(app.staticTexts["Error: unknown model \"opus-9\""].waitForExistence(timeout: 10))
        capture("template-invalid")
    }

    func testLeavingADirtyTemplateAsks() {
        openTemplate("coder")
        editModel()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5) || app.sheets.firstMatch.waitForExistence(timeout: 5))
        capture("template-leave")
    }

    func testTaskDetailPromptHistoryAndLog() {
        openMachine("Dionysus")
        app.cells["machine.config.tasks"].tap()
        app.cells["tasks.row.heartbeat"].tap()
        XCTAssertTrue(app.cells["config.field.schedule"].waitForExistence(timeout: 10))
        capture("task-detail")
        scrollForm()
        capture("task-detail-middle")
        scrollForm(until: app.cells["config.link.history"])
        XCTAssertTrue(app.cells["config.link.history"].waitForExistence(timeout: 10))
        capture("task-detail-links")

        app.cells["config.link.prompt"].tap()
        XCTAssertTrue(app.textViews["task.prompt.text"].waitForExistence(timeout: 10))
        capture("task-prompt")
        backOut()

        scrollForm(until: app.cells["config.link.history"])
        app.cells["config.link.history"].tap()
        let run = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'task.history.run.'")).firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        capture("task-history")

        run.tap()
        XCTAssertTrue(app.textViews["task.log.text"].waitForExistence(timeout: 10))
        capture("task-log")
    }

    func testServiceAndItsRestart() {
        openMachine("Dionysus")
        app.cells["machine.config.service"].tap()
        XCTAssertTrue(app.cells["service.action.restartDaemon"].waitForExistence(timeout: 10))
        capture("service")

        app.cells["service.action.restartDaemon"].tap()
        let dialog = app.alerts.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 10))
        capture("service-restart-confirm")

        dialog.buttons.matching(NSPredicate(format: "label != 'Cancel'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["config.banner.restarting"].waitForExistence(timeout: 10))
        capture("service-restarting")
    }

    // MARK: driving

    private func first(of list: String) -> String {
        ["templates": "coder", "environments": "base", "tasks": "heartbeat"][list] ?? ""
    }

    private func openMachine(_ name: String, arguments: [String] = []) {
        let launched = XCUIApplication()
        launched.launchArguments = ["-settingsFixture"] + arguments
        launched.launch()
        app = launched
        let cell = launched.cells["daemon.\(name)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "\(name) never listed")
        cell.tap()
    }

    private func openTemplate(_ name: String, arguments: [String] = []) {
        openMachine("Dionysus", arguments: arguments)
        app.cells["machine.config.templates"].tap()
        let row = app.cells["config.row.\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.collectionViews["config.form"].waitForExistence(timeout: 10))
    }

    /// Types into the Model field, which dirties the draft.
    private func editModel() {
        let field = app.cells["config.field.model"].textFields["field.control"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText("-9")
        dismissKeyboard()
    }

    /// Drags down through the keyboard: the form dismisses it interactively.
    private func dismissKeyboard() {
        let form = app.collectionViews["config.form"]
        form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        settle()
    }

    private func backOut() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func scrollForm(until element: XCUIElement, attempts: Int = 6) {
        for _ in 0..<attempts where !element.exists || !element.isHittable { scrollForm() }
    }

    /// Most of a screen up, so the next capture is the rows below.
    private func scrollForm() {
        let form = app.collectionViews["config.form"]
        let from = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        from.press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        settle()
    }

    // MARK: capture

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private func capture(_ name: String) {
        XCUIDevice.shared.appearance = .light
        settle()
        write(XCUIScreen.main.screenshot(), "\(name)-light")
        XCUIDevice.shared.appearance = .dark
        settle()
        write(XCUIScreen.main.screenshot(), "\(name)-dark")
        XCUIDevice.shared.appearance = .light
    }

    private func write(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = environment["LEO_SCREENSHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = screenshot.image.size
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            screenshot.image.draw(in: CGRect(origin: .zero, size: size))
        }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
