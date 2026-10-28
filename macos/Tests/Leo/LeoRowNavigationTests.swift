import Testing

@testable import Ghostty

/// B-059: which row a keyboard move lands on, given the rows the sidebar
/// lists (in display order) and the selected one.
struct LeoRowNavigationTests {
    private let rows = ["a", "b", "c", "d"]

    @Test func numberSelectsNthRow() {
        #expect(LeoRowNavigation.target(.number(1), in: rows, selected: "d") == "a")
        #expect(LeoRowNavigation.target(.number(3), in: rows, selected: nil) == "c")
    }

    /// Ghostty's own `goto_tab:N` clamps to the last tab.
    @Test func numberPastEndSelectsLastRow() {
        #expect(LeoRowNavigation.target(.number(8), in: rows, selected: "a") == "d")
    }

    @Test func lastSelectsLastRow() {
        #expect(LeoRowNavigation.target(.last, in: rows, selected: "a") == "d")
    }

    @Test func nextAdvancesAndWrapsToFirst() {
        #expect(LeoRowNavigation.target(.next, in: rows, selected: "b") == "c")
        #expect(LeoRowNavigation.target(.next, in: rows, selected: "d") == "a")
    }

    @Test func previousStepsBackAndWrapsToLast() {
        #expect(LeoRowNavigation.target(.previous, in: rows, selected: "c") == "b")
        #expect(LeoRowNavigation.target(.previous, in: rows, selected: "a") == "d")
    }

    @Test func nextWithoutSelectionSelectsFirst() {
        #expect(LeoRowNavigation.target(.next, in: rows, selected: nil) == "a")
        #expect(LeoRowNavigation.target(.next, in: rows, selected: "gone") == "a", "a selection the list doesn't show")
    }

    @Test func previousWithoutSelectionSelectsLast() {
        #expect(LeoRowNavigation.target(.previous, in: rows, selected: nil) == "d")
    }

    @Test func emptyListHasNoTarget() {
        for move in [LeoRowMove.number(1), .last, .next, .previous] {
            #expect(LeoRowNavigation.target(move, in: [String](), selected: nil) == nil, "\(move)")
        }
    }
}
