import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-409: Clear Site Data asks first, names whose data goes, and Cancel is
/// the safe default.
@MainActor struct LeoClearSiteDataConfirmationTests {
    /// Cancel comes first; AppKit gives a Cancel button Escape, and Clear
    /// never answers Return, so a stray Return can't clear.
    @Test func alertNamesTheAgentDefaultsToCancelAndClearIsDestructive() {
        let alert = LeoClearSiteDataConfirmation.makeAlert(agent: LeoAgentBrowserKey(host: .local, agent: "alpha"))

        #expect(alert.messageText == "Clear site data for “alpha”?")
        #expect(alert.informativeText.contains("Other agents keep theirs"))
        #expect(alert.buttons.map(\.title) == ["Cancel", "Clear Site Data"])
        #expect(alert.buttons.map(\.hasDestructiveAction) == [false, true])
        #expect(alert.buttons.last?.keyEquivalent != "\r", "Return never picks Clear")
    }

    @Test func aRemoteAgentsAlertNamesItsMachine() {
        let alert = LeoClearSiteDataConfirmation.makeAlert(agent: LeoAgentBrowserKey(host: .remote("dionysus"), agent: "alpha"))

        #expect(alert.messageText == "Clear site data for “alpha” on dionysus?")
    }

    @Test func theUnavailableAlertGivesTheReason() {
        let alert = LeoClearSiteDataConfirmation.makeUnavailableAlert(reason: "dionysus is not connected, so port 5173 on it can't be reached")

        #expect(alert.messageText == "Can’t open this page in your default browser")
        #expect(alert.informativeText == "dionysus is not connected, so port 5173 on it can't be reached")
        #expect(alert.buttons.map(\.title) == ["OK"])
    }
}
