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

    private func pasteIntoComposer(_ app: XCUIApplication) {
        let field = app.textViews["chat.composer.text"]
        field.tap()
        field.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the edit menu offers Paste")
        paste.tap()
        // The first read of another process's pasteboard asks permission.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
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
        pasteIntoComposer(app)
        XCTAssertTrue(attachChip(app).waitForExistence(timeout: 5), "the pasted image is attached")
        snapshot("image-pasted")
        XCTAssertEqual(app.textViews["chat.composer.text"].value as? String ?? "", "")
    }

    func testPastingTextStaysText() throws {
        UIPasteboard.general.string = "hello paste"
        let app = openThread()
        pasteIntoComposer(app)
        XCTAssertEqual(app.textViews["chat.composer.text"].value as? String, "hello paste")
        XCTAssertFalse(attachChip(app).exists)
        snapshot("text-pasted")
    }
}
