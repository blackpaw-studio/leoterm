import AppKit
import Testing

@testable import Ghostty

/// Where a surfaced `path:line:column` puts the caret.
struct LeoEditorTextViewTests {
    private let text = "ab\ncdef\nlast" as NSString

    @Test func theCaretLandsOnTheLineAndColumn() {
        #expect(LeoEditorTextView.caret(line: 2, column: 3, in: text) == .init(location: 5, line: NSRange(location: 3, length: 5)))
        #expect(LeoEditorTextView.caret(line: 1, column: nil, in: text) == .init(location: 0, line: NSRange(location: 0, length: 3)))
    }

    @Test func aColumnPastTheLineStopsAtItsEnd() {
        #expect(LeoEditorTextView.caret(line: 1, column: 40, in: text) == .init(location: 2, line: NSRange(location: 0, length: 3)))
    }

    /// Terminal output is untrusted: no position may overflow the caret
    /// arithmetic.
    @Test func hugePositionsStopAtTheEndOfTheText() {
        #expect(LeoEditorTextView.caret(line: Int.max, column: Int.max, in: text) == .init(location: 12, line: NSRange(location: 8, length: 4)))
        #expect(LeoEditorTextView.caret(line: 2, column: Int.max, in: text) == .init(location: 7, line: NSRange(location: 3, length: 5)))
        #expect(LeoEditorTextView.caret(line: Int.min, column: Int.min, in: text) == .init(location: 0, line: NSRange(location: 0, length: 3)))
        let trailing = "a\n" as NSString
        #expect(LeoEditorTextView.caret(line: Int.max, column: Int.max, in: trailing) == .init(location: 2, line: NSRange(location: 2, length: 0)))
    }
}
