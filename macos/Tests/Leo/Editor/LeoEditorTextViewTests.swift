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

    /// Refuses every edit the way the pane does once a close is decided:
    /// from `textDidChange`, before the edit has finished.
    private final class Refuser: NSObject, NSTextViewDelegate {
        var original: String
        /// Vetoes edits outright, the way AppKit's own checks can.
        var vetoes = false
        init(_ original: String) { self.original = original }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            !vetoes
        }

        func textDidChange(_ notification: Notification) {
            (notification.object as? LeoEditorTextView)?.revertEdit(to: original)
        }
    }

    /// Selects `range` in `text`, then types over it the way a key press
    /// does; `refuser` puts back its `original`.
    private func typeOver(_ range: NSRange, in textView: LeoEditorTextView, refuser: Refuser) {
        textView.delegate = refuser
        textView.setSelectedRange(range)
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func loaded() -> LeoEditorTextView {
        let (_, textView) = LeoEditorTextView.make()
        textView.load(text, keepingSelection: false)
        return textView
    }

    @Test func aRefusedKeystrokeRestoresAMultiCharacterSelection() {
        let textView = loaded(), refuser = Refuser(text)
        typeOver(NSRange(location: 0, length: 5), in: textView, refuser: refuser)
        #expect(textView.string == text)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 5))
    }

    @Test func aRefusedKeystrokeRestoresASelectionAtTheEnd() {
        let textView = loaded(), refuser = Refuser(text)
        typeOver(NSRange(location: 6, length: 5), in: textView, refuser: refuser)
        #expect(textView.selectedRange() == NSRange(location: 6, length: 5))
    }

    @Test func aRefusedKeystrokeClampsTheSelectionToShorterText() {
        let textView = loaded(), refuser = Refuser("hello")
        typeOver(NSRange(location: 3, length: 8), in: textView, refuser: refuser)
        #expect(textView.string == "hello")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 2))
        refuser.original = ""
        typeOver(NSRange(location: 4, length: 1), in: textView, refuser: refuser)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    /// An edit vetoed before it starts leaves no record behind for the
    /// next refused edit to restore.
    @Test func aVetoedEditDoesNotLeakItsSelectionIntoTheNextRevert() {
        let textView = loaded(), refuser = Refuser(text)
        refuser.vetoes = true
        typeOver(NSRange(location: 0, length: 5), in: textView, refuser: refuser)
        #expect(textView.string == text)
        refuser.vetoes = false
        typeOver(NSRange(location: 6, length: 5), in: textView, refuser: refuser)
        #expect(textView.selectedRange() == NSRange(location: 6, length: 5))
    }

    /// A clamped endpoint never splits a surrogate pair or a composed
    /// sequence.
    @Test func restoredSelectionsSnapToComposedCharacters() {
        let emoji = "a\u{1F44D}\u{1F3FD}b" // a, thumbs up + skin tone (4 UTF-16 units), b
        let textView = loaded()
        typeOver(NSRange(location: 0, length: 3), in: textView, refuser: Refuser(emoji))
        #expect(textView.selectedRange() == NSRange(location: 0, length: 5))

        textView.delegate = nil
        textView.load(text, keepingSelection: false)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.load(emoji, keepingSelection: true)
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
        textView.load("ae\u{301}", keepingSelection: true)
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    /// A reload from disk may be unrelated text: only a caret survives,
    /// where it still fits.
    @Test func reloadingLeavesACaretAtTheOldLocation() {
        let (_, textView) = LeoEditorTextView.make()
        textView.load(text, keepingSelection: false)
        textView.setSelectedRange(NSRange(location: 6, length: 5))
        textView.load("something else entirely", keepingSelection: true)
        #expect(textView.selectedRange() == NSRange(location: 6, length: 0))
        textView.setSelectedRange(NSRange(location: 6, length: 5))
        textView.load("hi", keepingSelection: true)
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
    }

    /// A compound edit (a smart substitution) asks twice before it lands:
    /// the selection kept is the one before the first.
    @Test func aCompoundEditKeepsTheSelectionBeforeItsFirstStep() {
        let (_, textView) = LeoEditorTextView.make()
        textView.load(text, keepingSelection: false)
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(textView.shouldChangeText(in: NSRange(location: 0, length: 5), replacementString: "x"))
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(textView.shouldChangeText(in: NSRange(location: 0, length: 1), replacementString: "y"))
        textView.revertEdit(to: text)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 5))
    }

    /// Once an edit has landed, a later revert doesn't reuse its selection.
    @Test func aCompletedEditForgetsItsSelection() {
        let textView = loaded()
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.revertEdit(to: text)
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
    }
}
