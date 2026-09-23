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

/// A keystroke that races the close lock is undone with the selection it
/// replaced, not the caret it left behind.
@MainActor
struct LeoEditorTextViewRevertTests {
    private let text = "hello world"

    /// Selects `range`, then types over it the way a key press does.
    private func typeOver(_ range: NSRange) -> LeoEditorTextView {
        let (_, textView) = LeoEditorTextView.make()
        textView.load(text, keepingSelection: false)
        textView.setSelectedRange(range)
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        return textView
    }

    @Test func aRefusedKeystrokeRestoresAMultiCharacterSelection() {
        let textView = typeOver(NSRange(location: 0, length: 5))
        #expect(textView.string == "x world")
        textView.revertEdit(to: text)
        #expect(textView.string == text)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 5))
    }

    @Test func aRefusedKeystrokeRestoresASelectionAtTheEnd() {
        let textView = typeOver(NSRange(location: 6, length: 5))
        textView.revertEdit(to: text)
        #expect(textView.selectedRange() == NSRange(location: 6, length: 5))
    }

    @Test func aRefusedKeystrokeClampsTheSelectionToShorterText() {
        let textView = typeOver(NSRange(location: 3, length: 8))
        textView.revertEdit(to: "hello")
        #expect(textView.string == "hello")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 2))
        textView.setSelectedRange(NSRange(location: 4, length: 1))
        textView.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.revertEdit(to: "")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func reloadingKeepsTheWholeSelection() {
        let (_, textView) = LeoEditorTextView.make()
        textView.load(text, keepingSelection: false)
        textView.setSelectedRange(NSRange(location: 6, length: 5))
        textView.load(text + "!", keepingSelection: true)
        #expect(textView.selectedRange() == NSRange(location: 6, length: 5))
        textView.load("hello wo", keepingSelection: true)
        #expect(textView.selectedRange() == NSRange(location: 6, length: 2))
    }
}
