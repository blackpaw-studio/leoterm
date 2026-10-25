import XCTest

/// Back from a chat or an agent returns to the Agents list on iPhone, with
/// the list intact, against the scripted `-navFixture` (no daemon needed).
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
        XCTAssertTrue(app.otherElements["chat.thread"].waitForExistence(timeout: 5))
        back(app)
        assertAtAgentsList(app, "back-from-chat-via-detail")
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
        XCTAssertTrue(app.otherElements["chat.thread"].waitForExistence(timeout: 5))
        back(app)
        attach(app, "back-to-chats")
        XCTAssertTrue(app.cells["chat.agent-1"].waitForExistence(timeout: 5))
        back(app)
        assertAtAgentsList(app, "back-to-agents")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
