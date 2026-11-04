import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// View ▸ Terminal (⌃⌘1) and View ▸ Chat (⌃⌘2): the Terminal | Chat
/// switch's segments, from the keyboard.
@MainActor
struct LeoViewMenuTests {
    private let agent = LeoAgentID(host: .local, name: "alpha")

    private func makeSession() -> LeoWindowSession {
        let session = LeoWindowSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        session.selectedAgent = { [agent] in agent }
        return session
    }

    @Test func showingChatSelectsItLikeAClickOnItsSegment() {
        let session = makeSession()
        session.setObservedContentWidth(2000)

        LeoViewMenuActions.show(.chat, in: session)

        #expect(session.viewChoices[agent] == .chat)
    }

    @Test func showingTerminalSelectsItLikeAClickOnItsSegment() {
        let session = makeSession()
        session.choose(.chat, for: agent)

        LeoViewMenuActions.show(.terminal, in: session)

        #expect(session.viewChoices[agent] == .terminal)
    }

    @Test func theItemsAreDisabledWithNoAgentSelected() {
        let session = LeoWindowSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        #expect(!LeoViewMenuActions.state(of: .terminal, in: session).isEnabled)
        #expect(!LeoViewMenuActions.state(of: .chat, in: session).isEnabled)
    }

    @Test func theShownPaneIsChecked() {
        let session = makeSession()

        #expect(LeoViewMenuActions.state(of: .terminal, in: session) == .init(isEnabled: true, isChecked: true))
        #expect(LeoViewMenuActions.state(of: .chat, in: session) == .init(isEnabled: true, isChecked: false))
    }

    @Test func theMainMenuHasTheTwoItemsOnControlCommandOneAndTwo() throws {
        let shortcuts = try LeoMenuXib.shortcuts()
        let terminal = try #require(shortcuts.first { $0.action == "showLeoTerminal:" })
        let chat = try #require(shortcuts.first { $0.action == "showLeoChat:" })

        #expect(terminal.title == "Terminal" && terminal.shortcut == "⌃⌘1")
        #expect(chat.title == "Chat" && chat.shortcut == "⌃⌘2")
    }

    @Test func noOtherMainMenuItemUsesControlCommandOneOrTwo() throws {
        let shortcuts = try LeoMenuXib.shortcuts()

        for key in ["⌃⌘1", "⌃⌘2"] {
            let holders = shortcuts.filter { $0.shortcut == key }.map(\.title)
            #expect(holders.count == 1, "\(key): \(holders)")
        }
    }
}
