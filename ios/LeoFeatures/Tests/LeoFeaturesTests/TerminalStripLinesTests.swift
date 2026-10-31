import Testing

@testable import LeoFeatures

struct TerminalStripLinesTests {
    @Test func keepsTheLastFiveRows() {
        let rows = (1...8).map { "row \($0)" }
        #expect(TerminalStripLines.bottom(rows, count: 5) == ["row 4", "row 5", "row 6", "row 7", "row 8"])
    }

    @Test func dropsTrailingBlankRowsBeforeCounting() {
        let rows = ["a", "b", "c", "", "   ", ""]
        #expect(TerminalStripLines.bottom(rows, count: 2) == ["b", "c"])
    }

    @Test func fewerRowsThanAskedAreFine() {
        #expect(TerminalStripLines.bottom(["a", "", "b"], count: 5) == ["a", "", "b"])
    }

    @Test func aBlankScreenHasNoLines() {
        #expect(TerminalStripLines.bottom(["", "  ", ""], count: 5).isEmpty)
        #expect(TerminalStripLines.bottom([], count: 5).isEmpty)
    }

    @Test func rowsKeepTheirInnerBlanksAndLeadingIndent() {
        #expect(TerminalStripLines.bottom(["  indented", "", "end"], count: 3) == ["  indented", "", "end"])
    }

    @Test func emptyTerminalCellsBecomeSpaces() {
        // The emulator reports a cell nothing was drawn in as NUL; a label stops reading at one.
        #expect(TerminalStripLines.bottom(["\0\0cost\0\0$0"], count: 5) == ["  cost  $0"])
        #expect(TerminalStripLines.bottom(["a", "\0\0\0"], count: 5) == ["a"])
    }
}
