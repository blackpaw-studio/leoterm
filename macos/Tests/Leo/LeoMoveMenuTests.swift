import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-324: what the Move To and Copy To submenus list, shared by the row's
/// context menu and the Agents menu.
struct LeoMoveMenuTests {
    @Test func hostsBecomeEntriesInOrder() {
        #expect(LeoMoveMenu.entries(.hosts(["nas", "work"])) == [.host("nas"), .host("work")])
    }

    @Test func aNotYetLoadedListSaysLoading() {
        #expect(LeoMoveMenu.entries(nil) == [.placeholder("Loading…")])
    }

    @Test func anUnreadableListIsUnavailable() {
        #expect(LeoMoveMenu.entries(.unavailable) == [.placeholder("Unavailable")])
    }

    @Test func noOtherHostsSaysSo() {
        #expect(LeoMoveMenu.entries(.hosts([])) == [.placeholder("No Other Machines")])
    }

    @Test func theMoveConfirmationNamesTheAgentAndHost() {
        #expect(LeoMoveMenu.confirmMessage(agent: "alpha", host: "nas") == "Move alpha to nas?")
        #expect(LeoMoveMenu.confirmDetail == "It stops here and resumes there.")
    }

    private static let chord: NSEvent.ModifierFlags = [.command, .control, .shift]

    @Test func shiftControlCommandMAndCPopTheMoveAndCopyMenus() {
        #expect(LeoMoveMenu.shortcut(characters: "m", modifiers: Self.chord) == .move)
        #expect(LeoMoveMenu.shortcut(characters: "C", modifiers: Self.chord) == .copy)
    }

    @Test func otherChordsAreNotMoveShortcuts() {
        #expect(LeoMoveMenu.shortcut(characters: "m", modifiers: [.command, .control]) == nil)
        #expect(LeoMoveMenu.shortcut(characters: "m", modifiers: Self.chord.union(.option)) == nil)
        #expect(LeoMoveMenu.shortcut(characters: "d", modifiers: Self.chord) == nil)
    }
}
