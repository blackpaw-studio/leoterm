import Darwin
import UIKit
import XCTest

/// The settings screens against a real, isolated leo 0.59.0 over `/api/v1`,
/// paired with the `leo pair --json` payload. Skipped unless the runner passes:
///   TEST_RUNNER_LEO_PAIRING_PAYLOAD  the payload (single use; pair afresh per run)
///   TEST_RUNNER_LEO_YAML             the daemon's leo.yaml, read and edited from here
///   TEST_RUNNER_LEO_WORKSPACE        the tasks' workspace (prompt files)
///   TEST_RUNNER_LEO_DAEMON_PIDFILE   the daemon's pid, rewritten by whatever respawns it
///   TEST_RUNNER_LEO_API_URL          the daemon's base URL, for noticing it is back
///   TEST_RUNNER_LEO_SCREENSHOTS      (optional) PNG directory
/// The simulator shares the host's filesystem and processes, so the test checks
/// leo.yaml on disk and stands in for launchd by SIGTERMing the daemon it was
/// handed the pid of (a scratch daemon under a respawn loop).
/// `testOldMachineRequiresANewerLeo` takes a 0.58.0 daemon's payload instead.
final class LeoSettingsE2ETests: XCTestCase {
    private var app: XCUIApplication!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(environment["LEO_PAIRING_PAYLOAD"] == nil, "No pairing payload; set TEST_RUNNER_LEO_PAIRING_PAYLOAD")
        XCUIDevice.shared.appearance = .light
        app = XCUIApplication()
        app.launchArguments = ["-resetForUITests", "-noAnimationsForUITests"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    // MARK: templates

    func testTemplateEditSavesAndAStaleSaveOverwrites() throws {
        try pairAndOpenMachine()
        openTemplate("coder")

        // A plain edit is written.
        editField("model", to: "haiku")
        try save()
        try eventually("model: haiku is on disk") { try yaml().contains("model: haiku") }
        capture("e2e-template-saved")

        // Someone else changes the file; Save is refused as stale, Overwrite
        // writes ours on top, and their change is still there.
        editField("model", to: "opus")
        try writeYAML(try yaml().replacingOccurrences(of: "max_turns: 10", with: "max_turns: 11"))
        app.buttons["config.save"].tap()
        let overwrite = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH '.Overwrite'")).firstMatch
        XCTAssertTrue(overwrite.waitForExistence(timeout: 20), "no conflict banner after a stale save")
        capture("e2e-template-conflict")
        overwrite.tap()
        try eventually("both sides of the 409 are on disk") {
            let text = try yaml()
            return text.contains("model: opus") && text.contains("max_turns: 11")
        }
    }

    // MARK: tasks

    func testTasksToggleRunNowAndPrompt() throws {
        try pairAndOpenMachine()
        app.cells["machine.config.tasks"].tap()
        let toggle = app.switches["tasks.enabled.nightly"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        capture("e2e-tasks")

        toggle.tap()
        try eventually("nightly is enabled on disk") { try !yaml().contains("enabled: false") }

        // Run Now runs the stub harness, and the run shows in History.
        let row = app.cells["tasks.row.heartbeat"]
        row.swipeRight()
        XCTAssertTrue(app.buttons["Run Now"].waitForExistence(timeout: 5))
        app.buttons["Run Now"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        row.tap()
        scrollForm(until: app.cells["config.link.history"])
        app.cells["config.link.history"].tap()
        let run = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'task.history.run.'")).firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 30), "Run Now left no run in History")
        capture("e2e-task-history")
        backOut()

        // The prompt saves to the task's file.
        scrollForm(until: app.cells["config.link.prompt"])
        app.cells["config.link.prompt"].tap()
        let text = app.textViews["task.prompt.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 20))
        text.tap()
        text.typeText(" FIRSTSAVE")
        app.buttons["task.prompt.save"].tap()
        let promptFile = try workspaceFile("heartbeat.md")
        try eventually("the prompt is on disk") { try String(contentsOfFile: promptFile, encoding: .utf8).contains("FIRSTSAVE") }

        // The task is repointed behind the app's back: the next save is refused
        // and the old file keeps what it had.
        try "Another file.\n".write(toFile: try workspaceFile("other.md"), atomically: true, encoding: .utf8)
        try writeYAML(try yaml().replacingOccurrences(of: "prompt_file: heartbeat.md", with: "prompt_file: other.md"))
        text.tap()
        text.typeText(" SECONDSAVE")
        app.buttons["task.prompt.save"].tap()
        let answered = app.sheets.firstMatch.waitForExistence(timeout: 20)
            || app.alerts.firstMatch.exists
            || app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'config.banner.' OR identifier BEGINSWITH 'task.prompt'")).firstMatch.exists
        XCTAssertTrue(answered, "a save after the file moved raised neither a question nor an error")
        capture("e2e-prompt-refused")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(try String(contentsOfFile: promptFile, encoding: .utf8).contains("SECONDSAVE"), "the save reached the old file")
    }

    // MARK: environments

    func testEnvironmentGainsAnEntry() throws {
        try pairAndOpenMachine()
        app.cells["machine.config.environments"].tap()
        let row = app.cells["config.row.work"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let variables = app.cells["config.field.env"]
        XCTAssertTrue(variables.waitForExistence(timeout: 20), "the Variables field never appeared")
        variables.tap()
        let add = app.cells["field.editor.add"]
        if !add.waitForExistence(timeout: 10) { capture("e2e-env-no-add") }
        XCTAssertTrue(add.exists, "the variables editor has no Add row")
        add.tap()
        let key = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'field.editor.key.'")).allElementsBoundByIndex.last
        let value = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'field.editor.value.'")).allElementsBoundByIndex.last
        let keyField = try XCTUnwrap(key)
        keyField.tap()
        keyField.typeText("E2E_VAR")
        let valueField = try XCTUnwrap(value)
        valueField.tap()
        valueField.typeText("hello")
        capture("e2e-env-editor")
        backOut()
        try save()
        try eventually("the entry is on disk") { try yaml().contains("E2E_VAR: hello") }
    }

    // MARK: service

    func testServiceLogRunsAndARestartIsWaitedOut() throws {
        try pairAndOpenMachine()
        app.cells["machine.config.service"].tap()
        let log = app.textViews["service.log"]
        XCTAssertTrue(log.waitForExistence(timeout: 20))
        try eventually("the log tail has text") { (log.value as? String)?.isEmpty == false }
        capture("e2e-service")

        let before = try daemonPID()
        XCTAssertEqual(shownPID(), before, "the Service screen shows another process than the scratch daemon")
        app.cells["service.action.restartDaemon"].tap()
        let dialog = app.alerts.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 10))
        dialog.buttons.matching(NSPredicate(format: "label != 'Cancel'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["config.banner.restarting"].waitForExistence(timeout: 10), "no restart banner")
        capture("e2e-service-waiting")

        // Nothing here is launchd, so the daemon is bounced by hand, and the
        // respawn loop brings it back as a new process.
        XCTAssertEqual(kill(before, SIGTERM), 0)
        try eventually("the restart banner clears", timeout: 120) { !app.staticTexts["config.banner.restarting"].exists }
        try eventually("the screen shows a new pid", timeout: 60) {
            guard let now = shownPID() else { return false }
            let running = try daemonPID()
            return now != before && now == running
        }
        capture("e2e-service-restarted")
    }

    func testAnOpenDraftSurvivesTheDaemonRestarting() throws {
        try pairAndOpenMachine()
        openTemplate("coder")
        editField("model", to: "sonnet-drafted")
        let before = try daemonPID()
        XCTAssertEqual(kill(before, SIGTERM), 0)
        try eventually("the daemon is back as a new process", timeout: 60) {
            let now = try daemonPID()
            return now != before && daemonAnswers()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(8))

        let field = app.cells["config.field.model"].textFields["field.control"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "sonnet-drafted")
        XCTAssertTrue(app.buttons["config.save"].isEnabled, "the draft stopped being dirty")
        capture("e2e-draft-after-restart")
        app.buttons["config.save"].tap()
        try eventually("the draft is saved after the reconnect", timeout: 30) { try yaml().contains("model: sonnet-drafted") }
    }

    // MARK: an older machine

    func testOldMachineRequiresANewerLeo() throws {
        try pairAndOpenMachine()
        XCTAssertTrue(app.cells["machine.config.requires"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.cells["machine.config.requires"].staticTexts["Requires leo ≥ 0.59.0"].exists)
        capture("e2e-machine-requires")
    }

    // MARK: driving

    private func pairAndOpenMachine() throws {
        let payload = try XCTUnwrap(environment["LEO_PAIRING_PAYLOAD"])
        app.tabBars.buttons["Agents"].tap()
        app.buttons["Pair a Daemon"].tap()
        let field = app.textViews["pairing.payload"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(payload)
        app.buttons["pairing.pair"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 30), "pairing never finished")
        app.tabBars.buttons["Machines"].tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 30), "the daemon never connected")
        let cell = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'daemon.'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.tap()
    }

    private func openTemplate(_ name: String) {
        app.cells["machine.config.templates"].tap()
        let row = app.cells["config.row.\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "\(name) never listed")
        row.tap()
        XCTAssertTrue(app.collectionViews["config.form"].waitForExistence(timeout: 10))
    }

    private func editField(_ path: String, to text: String) {
        let field = app.cells["config.field.\(path)"].textFields["field.control"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // At the end of the text, so the deletes below take it all out.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    private func save() throws {
        app.buttons["config.save"].tap()
        try eventually("Save is done") { !app.buttons["config.save"].isEnabled }
    }

    private func backOut() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func scrollForm(until element: XCUIElement, attempts: Int = 8) {
        let form = app.collectionViews["config.form"]
        for _ in 0..<attempts where !element.exists || !element.isHittable {
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
    }

    // MARK: the host

    private func yamlPath() throws -> String { try XCTUnwrap(environment["LEO_YAML"], "TEST_RUNNER_LEO_YAML") }

    private func yaml() throws -> String { try String(contentsOfFile: try yamlPath(), encoding: .utf8) }

    private func writeYAML(_ text: String) throws {
        try text.write(toFile: try yamlPath(), atomically: true, encoding: .utf8)
    }

    private func workspaceFile(_ name: String) throws -> String {
        (try XCTUnwrap(environment["LEO_WORKSPACE"], "TEST_RUNNER_LEO_WORKSPACE") as NSString).appendingPathComponent(name)
    }

    private func daemonPID() throws -> pid_t {
        let file = try XCTUnwrap(environment["LEO_DAEMON_PIDFILE"], "TEST_RUNNER_LEO_DAEMON_PIDFILE")
        let text = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(text), "no pid in \(file)")
    }

    /// The pid the Service screen's Process row shows.
    private func shownPID() -> pid_t? {
        let row = app.cells["service.detail.Process"]
        guard row.exists else { return nil }
        return row.staticTexts.allElementsBoundByIndex.compactMap { pid_t($0.label) }.first
    }

    /// Whether the daemon answers at all (401 without a token counts).
    private func daemonAnswers() -> Bool {
        guard let base = environment["LEO_API_URL"], let url = URL(string: base + "/api/v1/version") else { return false }
        final class Answer: @unchecked Sendable { var isHTTP = false }
        let done = DispatchSemaphore(value: 0)
        let answer = Answer()
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, _ in
            answer.isHTTP = response is HTTPURLResponse
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return answer.isHTTP
    }

    private func eventually(_ what: String, timeout: TimeInterval = 20, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("never: \(what)")
    }

    // MARK: capture

    private func capture(_ name: String) {
        for (suffix, appearance) in [("light", XCUIDevice.Appearance.light), ("dark", .dark)] {
            XCUIDevice.shared.appearance = appearance
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "\(name)-\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let directory = environment["LEO_SCREENSHOTS"] else { continue }
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let size = screenshot.image.size
            let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
                screenshot.image.draw(in: CGRect(origin: .zero, size: size))
            }
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png"))
        }
        XCUIDevice.shared.appearance = .light
    }
}
