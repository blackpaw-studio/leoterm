import UIKit
import XCTest

/// Back from a chat or an agent returns one level at a time on iPhone, with
/// the list intact; each tab keeps its own selection. Runs against the
/// scripted `-navFixture` (no daemon needed).
final class LeoNavStackTests: XCTestCase {
    private let agents = ["agent-0", "agent-1", "agent-2"]

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-navFixture"]
        app.launch()
        XCTAssertTrue(app.cells["chat.agent-0"].waitForExistence(timeout: 10))
        return app
    }

    private func openTab(_ app: XCUIApplication, _ name: String) {
        app.tabBars.buttons[name].tap()
    }

    private func assertAtAgentsList(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        attach(app, step)
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5), "\(step): Agents bar", file: file, line: line)
        for agent in agents {
            XCTAssertTrue(app.cells["agent.\(agent)"].exists, "\(step): row \(agent)", file: file, line: line)
        }
    }

    private func assertAtInbox(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        attach(app, step)
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5), "\(step): Chats bar", file: file, line: line)
        for agent in agents {
            XCTAssertTrue(app.cells["chat.\(agent)"].exists, "\(step): row \(agent)", file: file, line: line)
        }
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func testLaunchesIntoTheInbox() throws {
        let app = launch()
        assertAtInbox(app, "launch")
        XCTAssertTrue(app.tabBars.buttons["Chats"].isSelected)
    }

    func testBackFromAChatOpenedFromTheInboxReturnsToTheInbox() throws {
        let app = launch()
        app.cells["chat.agent-1"].tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5))
        back(app)
        assertAtInbox(app, "back-to-inbox")
    }

    func testBackFromAChatStartedFromTheNewChatPickerReturnsToTheInbox() throws {
        let app = launch()
        app.buttons["New Chat"].tap()
        let pick = app.cells["newChat.agent-2"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        pick.tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5))
        back(app)
        assertAtInbox(app, "back-to-inbox-after-new-chat")
    }

    func testBackFromDetailReturnsToTheAgentsList() throws {
        let app = launch()
        openTab(app, "Agents")
        app.cells["agent.agent-0"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        back(app)
        assertAtAgentsList(app, "back-from-detail")
    }

    func testReopeningTheSameAgentAfterBackShowsItAgain() throws {
        let app = launch()
        openTab(app, "Agents")
        app.cells["agent.agent-0"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        back(app)
        assertAtAgentsList(app, "reopen-first-back")
        app.cells["agent.agent-0"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        back(app)
        assertAtAgentsList(app, "reopen-second-back")
    }

    /// The detail's Chat button opens the thread on the Chats tab; the detail
    /// stays where it was on the Agents tab.
    func testChatFromDetailSwitchesToTheChatsTabAndLeavesTheDetail() throws {
        let app = launch()
        openTab(app, "Agents")
        app.cells["agent.agent-0"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        app.cells["agent.chat"].tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Chats"].isSelected, "Chats tab selected")
        back(app)
        assertAtInbox(app, "back-from-chat-to-inbox")
        openTab(app, "Agents")
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5), "the Agents tab still shows the detail")
        XCTAssertFalse(app.collectionViews["chat.thread"].exists)
    }

    /// Regular width: the inbox stays beside the thread, and the agents list
    /// beside the detail, while the selection moves.
    func testSplitViewKeepsTheListBesideTheSelection() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "regular width only")
        let app = launch()
        app.cells["chat.agent-0"].tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5))
        for agent in agents {
            XCTAssertTrue(app.cells["chat.\(agent)"].exists, "ipad chat: row \(agent)")
        }
        attach(app, "ipad-chat")
        app.cells["chat.agent-1"].tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].exists)
        attach(app, "ipad-second-chat")

        openTab(app, "Agents")
        app.cells["agent.agent-0"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        for agent in agents {
            XCTAssertTrue(app.cells["agent.\(agent)"].exists, "ipad detail: row \(agent)")
        }
        attach(app, "ipad-detail")
        app.cells["agent.agent-1"].tap()
        XCTAssertTrue(app.cells["agent.chat"].waitForExistence(timeout: 5))
        attach(app, "ipad-second-agent")
    }

    /// A Pro Max-class iPhone is regular width in landscape: the split view
    /// expands (pulling the secondary off the stack) and collapses again.
    /// Neither may read as the user popping back.
    func testRotatingAcrossTheSizeClassKeepsTheOpenChat() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone only")
        let app = launch()
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        app.cells["chat.agent-0"].tap()
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5), "landscape: chat stays")
        attach(app, "rotate-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.collectionViews["chat.thread"].waitForExistence(timeout: 5), "portrait again: chat stays")
        attach(app, "rotate-portrait")
        XCTAssertFalse(app.staticTexts["No Chat Selected"].exists, "placeholder")
        back(app)
        assertAtInbox(app, "back-after-rotation")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
