/// Where keyboard focus goes when the pane's drawer changes. Pure: the app
/// side turns the answer into `makeFirstResponder` calls.
enum LeoAgentPaneFocus {
    /// What the pane shows that decides who may hold the keyboard.
    struct Drawer: Equatable {
        let isExpanded: Bool
        let selectedIsTerminal: Bool

        /// The Terminal's body is on screen.
        var showsTerminal: Bool { isExpanded && selectedIsTerminal }
    }

    enum Move: Equatable {
        /// The drawer terminal takes the keyboard.
        case focusDrawer
        /// The keyboard goes back to the agent's main view.
        case focusMain
        case none
    }

    /// Opening onto the Terminal (expanding it, or switching to its tab with
    /// the drawer open) focuses it. When the drawer terminal had the keyboard
    /// and stops being shown (collapsed, or another tab), the keyboard goes
    /// back to the main view. Anything else leaves focus alone, so a plain
    /// agent switch or a click elsewhere is never overridden.
    static func transition(from: Drawer, to: Drawer, drawerHasFocus: Bool) -> Move {
        if to.showsTerminal, !from.showsTerminal { return .focusDrawer }
        if drawerHasFocus, !to.showsTerminal { return .focusMain }
        return .none
    }
}
