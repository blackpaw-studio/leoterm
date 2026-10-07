import AppKit
import Testing

@testable import Ghostty

/// B-262: Clear asks first, and Cancel is the safe default.
@MainActor struct LeoClearConfirmationTests {
    /// NSAlert makes its first button the default.
    @Test func alertNamesTheAgentAndDefaultsToCancel() {
        let alert = LeoClearConfirmation.makeAlert(agent: "alpha")
        #expect(alert.messageText == "Clear alpha’s conversation?")
        #expect(alert.buttons.map(\.title) == ["Cancel", "Clear"])
    }

    @Test func clearIsTheDestructiveButton() {
        let alert = LeoClearConfirmation.makeAlert(agent: "alpha")
        #expect(!alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[1].hasDestructiveAction)
    }
}
