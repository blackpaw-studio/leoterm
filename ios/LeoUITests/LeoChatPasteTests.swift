import UIKit
import XCTest

/// Pasting into the chat composer: an image-only pasteboard attaches, text
/// still pastes as text. Runs against the scripted `-navFixture`.
final class LeoChatPasteTests: XCTestCase {
    private func openThread() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-navFixture", "-noAnimationsForUITests"]
        app.launch()
        let row = app.cells["chat.agent-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
        return app
    }

    override func setUp() {
        continueAfterFailure = false
        UIPasteboard.general.items = []
    }

    /// Pastes through the edit menu, then waits for `done`; the first read of
    /// another process's pasteboard asks permission, so "Allow Paste" is tapped when it shows.
    private func pasteIntoComposer(_ app: XCUIApplication, until done: () -> Bool) {
        let field = app.textViews["chat.composer.text"]
        field.tap()
        let focused = expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        wait(for: [focused], timeout: 5)
        field.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the edit menu offers Paste")
        paste.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !done() {
            if allow.exists { allow.tap() }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(done(), "the paste landed")
    }

    private func attachChip(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove Pasted image")).firstMatch
    }

    private func png() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPastingAnImageAttachesIt() throws {
        UIPasteboard.general.image = png()
        let app = openThread()
        pasteIntoComposer(app) { attachChip(app).exists }
        snapshot("image-pasted")
        XCTAssertEqual(app.textViews["chat.composer.text"].value as? String ?? "", "")
    }

    /// A file copied in Files carries its content type (here PDF), not a file URL.
    func testPastingADocumentAttachesIt() throws {
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 72, height: 72)).pdfData { $0.beginPage() }
        UIPasteboard.general.setData(pdf, forPasteboardType: "com.adobe.pdf")
        let app = openThread()
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove ")).firstMatch
        pasteIntoComposer(app) { chip.exists }
        snapshot("document-pasted")
    }

    func testPastingTextStaysText() throws {
        UIPasteboard.general.string = "hello paste"
        let app = openThread()
        pasteIntoComposer(app) { app.textViews["chat.composer.text"].value as? String == "hello paste" }
        XCTAssertEqual(app.textViews["chat.composer.text"].value as? String, "hello paste")
        XCTAssertFalse(attachChip(app).exists)
        snapshot("text-pasted")
    }

    /// A copied web link with no plain string is text for the field, not a file.
    func testPastingALinkStaysText() throws {
        UIPasteboard.general.url = URL(string: "https://example.com/paste")
        let app = openThread()
        pasteIntoComposer(app) { app.textViews["chat.composer.text"].value as? String == "https://example.com/paste" }
        XCTAssertFalse(attachChip(app).exists)
    }
}
