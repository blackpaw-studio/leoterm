import Testing

@testable import Ghostty

/// Covers the flag's two transitions indirectly: `false` (a normal window,
/// or a filled placeholder after `TerminalController.
/// leoRegisterFilledPlaceholderUndo` runs) closes on an empty tree exactly
/// like upstream; `true` (a fresh, still-unfilled placeholder) does not.
struct LeoPlaceholderCloseDecisionTests {
    @Test func emptyTreeAndNotAPlaceholderCloses() {
        #expect(LeoPlaceholderCloseDecision.shouldCloseOnEmptyTree(isEmpty: true, isUnfilledPlaceholder: false))
    }

    @Test func emptyTreeAndStillAnUnfilledPlaceholderDoesNotClose() {
        #expect(!LeoPlaceholderCloseDecision.shouldCloseOnEmptyTree(isEmpty: true, isUnfilledPlaceholder: true))
    }

    /// A reborn leaf (an agent surface that exited in a split or alongside
    /// other tabs) is overlaid with the placeholder view in place -- the
    /// split tree itself is never emptied, so `isEmpty` is `false` here
    /// regardless of `isUnfilledPlaceholder` (which only ever describes the
    /// *whole-window* empty-tree placeholder, not a per-leaf rebirth). The
    /// window-close guard must never fire for this case.
    @Test func nonEmptyTreeNeverClosesRegardlessOfTheFlag() {
        #expect(!LeoPlaceholderCloseDecision.shouldCloseOnEmptyTree(isEmpty: false, isUnfilledPlaceholder: false))
        #expect(!LeoPlaceholderCloseDecision.shouldCloseOnEmptyTree(isEmpty: false, isUnfilledPlaceholder: true))
    }
}
