import Testing

@testable import Ghostty

struct LeoAgentPaneFocusTests {
    private typealias Drawer = LeoAgentPaneFocus.Drawer
    private let collapsed = Drawer(isExpanded: false, selectedIsTerminal: true)
    private let onTerminal = Drawer(isExpanded: true, selectedIsTerminal: true)
    private let onStatus = Drawer(isExpanded: true, selectedIsTerminal: false)

    @Test func expandingOntoTheTerminalFocusesTheDrawer() {
        #expect(LeoAgentPaneFocus.transition(from: collapsed, to: onTerminal, drawerHasFocus: false) == .focusDrawer)
    }

    @Test func switchingToTheTerminalTabWithTheDrawerOpenFocusesIt() {
        #expect(LeoAgentPaneFocus.transition(from: onStatus, to: onTerminal, drawerHasFocus: false) == .focusDrawer)
    }

    @Test func collapsingWithTheDrawerFocusedReturnsToTheMainView() {
        #expect(LeoAgentPaneFocus.transition(from: onTerminal, to: collapsed, drawerHasFocus: true) == .focusMain)
    }

    @Test func switchingAwayFromTheTerminalTabWithTheDrawerFocusedReturnsToTheMainView() {
        #expect(LeoAgentPaneFocus.transition(from: onTerminal, to: onStatus, drawerHasFocus: true) == .focusMain)
    }

    @Test func collapsingWithoutDrawerFocusDoesNothing() {
        #expect(LeoAgentPaneFocus.transition(from: onTerminal, to: collapsed, drawerHasFocus: false) == .none)
    }

    @Test func expandingOntoAnotherTabOrStayingPutDoesNothing() {
        #expect(LeoAgentPaneFocus.transition(from: collapsed, to: onStatus, drawerHasFocus: false) == .none)
        #expect(LeoAgentPaneFocus.transition(from: onTerminal, to: onTerminal, drawerHasFocus: true) == .none)
        #expect(LeoAgentPaneFocus.transition(from: onTerminal, to: onTerminal, drawerHasFocus: false) == .none)
    }
}
