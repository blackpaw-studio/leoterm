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

    // MARK: The toolbar switch's presentation

    @Test func theSwitchIsDisabledWithNoAgentShown() {
        let session = LeoWindowSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let presentation = LeoViewMenuActions.switchPresentation(in: session, unread: { _ in 5 })

        #expect(presentation == LeoViewSwitchPresentation(layout: nil, unreadCount: 0))
    }

    @Test func theSwitchShowsTheShownAgentsLayoutAndUnreadCount() {
        let session = makeSession()

        let terminalOnly = LeoViewMenuActions.switchPresentation(in: session, unread: { $0 == agent ? 3 : 0 })
        #expect(terminalOnly == LeoViewSwitchPresentation(layout: .terminal, unreadCount: 3))
        #expect(terminalOnly.showsUnreadDot)

        session.setObservedContentWidth(2000)
        session.choose(.chat, for: agent)
        let sideBySide = LeoViewMenuActions.switchPresentation(in: session, unread: { _ in 3 })
        #expect(sideBySide.selected == [.terminal, .chat])
        #expect(!sideBySide.showsUnreadDot)
    }

    // MARK: Message Agent

    @Test func messageAgentShowsChatAndFocusesItsComposer() {
        let session = makeSession()
        session.setObservedContentWidth(800)
        let before = session.chatFocusRequest

        LeoViewMenuActions.messageAgent(in: session)

        #expect(session.viewChoices[agent] == .chat)
        #expect(session.chatFocusRequest == before + 1)
    }

    @Test func messageAgentKeepsChatOpenWhenItAlreadyShows() {
        let session = makeSession()
        session.setObservedContentWidth(800)
        session.choose(.chat, for: agent)

        LeoViewMenuActions.messageAgent(in: session)

        // Unlike the View ▸ Chat toggle, it never closes chat.
        #expect(session.viewChoices[agent] == .chat)
    }

    @Test func messageAgentIsEnabledWheneverAnAgentIsShown() {
        #expect(LeoViewMenuActions.canMessage(in: makeSession()))
        #expect(!LeoViewMenuActions.canMessage(in: LeoWindowSession(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
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
