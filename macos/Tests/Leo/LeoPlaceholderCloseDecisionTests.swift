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

    @Test func nonEmptyTreeNeverClosesRegardlessOfTheFlag() {
        #expect(!LeoPlaceholderCloseDecision.shouldCloseOnEmptyTree(isEmpty: false, isUnfilledPlaceholder: false))
        #expect(!LeoPlaceholderCloseDecision.shouldCloseOnEmptyTree(isEmpty: false, isUnfilledPlaceholder: true))
    }
}
