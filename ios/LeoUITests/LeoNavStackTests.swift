import UIKit
import XCTest

/// Back from a chat or an agent returns one level at a time on iPhone (a chat
/// opened from a detail returns to it first), with the list intact, against the scripted `-navFixture` (no daemon needed).
final class LeoNavStackTests: XCTestCase {
    private let agents = ["agent-0", "agent-1", "agent-2"]

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-navFixture"]
        app.launch()
        XCTAssertTrue(app.cells["agent.agent-0"].waitForExistence(timeout: 10))
        return app
    }

    private func assertAtAgentsList(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        attach(app, step)
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5), "\(step): Agents bar", file: file, line: line)
        for agent in agents {
            XCTAssertTrue(app.cells["agent.\(agent)"].exists, "\(step): row \(agent)", file: file, line: line)
        }
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func testBackFromChatOpenedFromDetailReturnsToTheList() throws {
        let app = launch()
        app.cells["agent.agent-0"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        app.cells["agent.chat"].tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5))
        back(app)
        attach(app, "back-from-chat-to-detail")
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5), "Back from the chat lands on the detail")
        XCTAssertFalse(app.collectionViews["chat.thread"].exists, "chat popped")
        back(app)
        assertAtAgentsList(app, "back-from-detail-after-chat")
    }

    func testBackFromDetailReturnsToTheList() throws {
        let app = launch()
        app.cells["agent.agent-0"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        back(app)
        assertAtAgentsList(app, "back-from-detail")
    }

    func testReopeningTheSameAgentAfterBackShowsItAgain() throws {
        let app = launch()
        app.cells["agent.agent-0"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        back(app)
        assertAtAgentsList(app, "reopen-first-back")
        app.cells["agent.agent-0"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        back(app)
        assertAtAgentsList(app, "reopen-second-back")
    }

    func testBackFromChatOpenedFromTheChatsListReturnsToChats() throws {
        let app = launch()
        app.navigationBars["Agents"].buttons["Chats"].tap()
        XCTAssertTrue(app.cells["chat.agent-1"].waitForExistence(timeout: 5))
        app.cells["chat.agent-1"].tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5))
        back(app)
        attach(app, "back-to-chats")
        XCTAssertTrue(app.cells["chat.agent-1"].waitForExistence(timeout: 5))
        back(app)
        assertAtAgentsList(app, "back-to-agents")
    }

    func testBackFromAChatStartedFromTheNewChatPickerReturnsToChats() throws {
        let app = launch()
        app.navigationBars["Agents"].buttons["Chats"].tap()
        XCTAssertTrue(app.cells["chat.agent-1"].waitForExistence(timeout: 5))
        app.buttons["New Chat"].tap()
        let pick = app.cells["newChat.agent-2"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        pick.tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5))
        back(app)
        XCTAssertTrue(app.cells["chat.agent-1"].waitForExistence(timeout: 5), "back to Chats")
        back(app)
        assertAtAgentsList(app, "back-to-agents-after-new-chat")
    }

    /// Regular width: the list stays beside the secondary column while the
    /// selection moves from an agent to its chat and to another agent.
    func testSplitViewKeepsTheListBesideTheSelection() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "regular width only")
        let app = launch()
        app.cells["agent.agent-0"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        attach(app, "ipad-detail")
        app.cells["agent.chat"].tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5))
        for agent in agents {
            XCTAssertTrue(app.cells["agent.\(agent)"].exists, "ipad chat: row \(agent)")
        }
        attach(app, "ipad-chat")
        // Back from the chat returns to its detail, beside the list.
        back(app)
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5), "ipad: Back lands on the detail")
        XCTAssertFalse(app.collectionViews["chat.thread"].exists, "ipad: chat popped")
        for agent in agents {
            XCTAssertTrue(app.cells["agent.\(agent)"].exists, "ipad detail: row \(agent)")
        }
        attach(app, "ipad-back-to-detail")
        app.cells["agent.chat"].tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5))
        app.cells["agent.agent-1"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.collectionViews["chat.thread"].exists)
        attach(app, "ipad-second-agent")
    }

    /// A Pro Max-class iPhone is regular width in landscape: the split view
    /// expands (pulling the secondary off the stack) and collapses again.
    /// Neither may read as the user popping back.
    func testRotatingAcrossTheSizeClassKeepsTheOpenChat() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone only")
        let app = launch()
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        app.cells["agent.agent-0"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        app.cells["agent.chat"].tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5), "landscape: chat stays")
        attach(app, "rotate-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5), "portrait again: chat stays")
        attach(app, "rotate-portrait")
        XCTAssertFalse(app.staticTexts["No Agent Selected"].exists, "placeholder")
        back(app)
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5), "Back after rotation lands on the detail")
        XCTAssertFalse(app.collectionViews["chat.thread"].exists, "chat popped")
        back(app)
        assertAtAgentsList(app, "back-after-rotation")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
