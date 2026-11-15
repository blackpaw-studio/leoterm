import Testing

@testable import Ghostty

/// Control feedback must never cover the chat composer: it floats over the
/// terminal column when that shows, and sits above the composer when Chat
/// replaces the terminal.
struct LeoControlFeedbackPlacementTests {
    @Test(arguments: [LeoChatLayout.terminal, .sideBySide])
    func aVisibleTerminalCarriesTheBannerOverItsOwnColumn(layout: LeoChatLayout) {
        #expect(LeoControlFeedbackPlacement(layout: layout) == .overTerminal)
    }

    @Test func chatReplacingTheTerminalShowsTheBannerAboveTheComposer() {
        #expect(LeoControlFeedbackPlacement(layout: .chatReplacingTerminal) == .aboveComposer)
    }
}
