import AppKit

/// View ▸ Terminal (⌃⌘1) and View ▸ Chat (⌃⌘2): the Terminal | Chat
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
