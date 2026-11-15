import AppKit
import LeoKit

/// View ▸ Terminal (⌃⌘1) and View ▸ Chat (⌃⌘2): the toolbar's Terminal | Chat
/// switch's segments from the keyboard. Choosing one is a click on that
/// segment (`select`), so Chat toggles off while it shows.
@MainActor
enum LeoViewMenuActions {
    struct State: Equatable {
        let isEnabled: Bool
        /// The pane is on screen.
        let isChecked: Bool
    }

    static func show(_ choice: LeoAgentViewChoice, in session: LeoWindowSession) {
        guard let agent = session.shownAgent else { return }
        session.select(choice, for: agent)
    }

    /// Agents ▸ Message Agent (⌃⌘M): Chat is where messages are written, so it
    /// shows Chat (never toggling it off) and focuses its composer. Leaves a
    /// full-window attachment first, which would cover the composer.
    static func messageAgent(in session: LeoWindowSession) {
        guard let agent = session.shownAgent else { return }
        session.chatViewer.exitFullWindow()
        session.choose(.chat, for: agent)
    }

    /// Message Agent works whenever an agent is shown.
    static func canMessage(in session: LeoWindowSession) -> Bool {
        session.shownAgent != nil
    }

    /// What the toolbar's switch shows for the agent on screen (nothing lit
    /// and disabled when none is).
    static func switchPresentation(in session: LeoWindowSession, unread: (LeoAgentID) -> Int) -> LeoViewSwitchPresentation {
        guard let agent = session.shownAgent else { return LeoViewSwitchPresentation(layout: nil, unreadCount: 0) }
        return LeoViewSwitchPresentation(layout: session.currentChatLayout, unreadCount: unread(agent))
    }

    static func state(of choice: LeoAgentViewChoice, in session: LeoWindowSession) -> State {
        guard session.shownAgent != nil else { return State(isEnabled: false, isChecked: false) }
        return State(isEnabled: true, isChecked: session.currentChatLayout.activeSegments.contains(choice))
    }
}

extension TerminalController {
    @IBAction func showLeoTerminal(_ sender: Any?) {
        leoSession.map { LeoViewMenuActions.show(.terminal, in: $0) }
    }

    @IBAction func showLeoChat(_ sender: Any?) {
        leoSession.map { LeoViewMenuActions.show(.chat, in: $0) }
    }

    /// Enables the item for an agent on screen and checks the pane it shows.
    func validateLeoViewMenuItem(_ item: NSMenuItem, _ choice: LeoAgentViewChoice) -> Bool {
        guard let leoSession else { return false }
        let state = LeoViewMenuActions.state(of: choice, in: leoSession)
        item.state = state.isChecked ? .on : .off
        return state.isEnabled
    }
}
