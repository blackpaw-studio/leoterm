import Foundation
import Testing

@testable import Ghostty

/// B-038: the disconnected banner's reason stays on one line with the full
/// reason as its tooltip, and the placeholder's "Choose Agent…" is
/// disabled while the feed is disconnected (D-067).
@MainActor struct LeoDisconnectedPresentationTests {
    // MARK: Banner

    @Test func theReasonIsShownOnOneLineWithTheFullReasonAsItsTooltip() throws {
        let raw = "LEO_FORCE_DISCONNECTED=1 forced this state after the first list\nfor screenshots"
        let banner = try #require(LeoDisconnectedBanner(host: .local, connectivity: .disconnected(reason: raw, isRetrying: false)))
        #expect(banner.reasonLineLimit == 1)
        #expect(banner.reasonHelp == LeoSFTPServerText.sanitized(raw))
        #expect(banner.reasonHelp == banner.reason)
    }

    // MARK: Choose Agent…

    @Test func chooseAgentIsEnabledWithItsShortcutAsHelpWhileConnected() {
        let state = LeoPlaceholderChooseAgent(host: .local, connectivity: .connected)
        #expect(state.isEnabled)
        #expect(state.isProminent)
        #expect(state.help == "⌘T")
    }

    @Test func chooseAgentIsDisabledWhileDisconnectedAndSaysHowToReconnect() {
        let state = LeoPlaceholderChooseAgent(host: .remote("mars"), connectivity: .disconnected(reason: "ssh exited (255)", isRetrying: false))
        #expect(!state.isEnabled)
        #expect(!state.isProminent)
        #expect(state.help == "Disconnected from mars. Reconnect first (⇧⌘R).")
    }

    /// Only a disconnected feed disables it: loading and failed states have
    /// their own panels, and the palette explains them.
    @Test func chooseAgentStaysEnabledOutsideTheDisconnectedState() {
        #expect(LeoPlaceholderChooseAgent(host: .local, connectivity: .loading).isEnabled)
        #expect(LeoPlaceholderChooseAgent(host: .local, connectivity: .failed(message: "x")).isEnabled)
        #expect(!LeoPlaceholderChooseAgent(host: .local, connectivity: .disconnected(reason: "x", isRetrying: true)).isEnabled)
    }

    /// Follows the sidebar model's snapshots: connect → disconnect → reconnect.
    @Test func chooseAgentFollowsTheFeedAcrossConnectDisconnectReconnect() {
        let model = LeoSidebarModel()
        func state() -> LeoPlaceholderChooseAgent {
            LeoPlaceholderChooseAgent(host: .local, connectivity: model.snapshot.connectivity)
        }

        model.receive(.init(rows: [], connectivity: .connected, generation: 1))
        #expect(state().isEnabled)

        model.receive(.init(rows: [], connectivity: .disconnected(reason: "Connection closed", isRetrying: false), generation: 2))
        #expect(!state().isEnabled)
        #expect(!state().isProminent)
        #expect(state().help == "Disconnected from localhost. Reconnect first (⇧⌘R).")

        model.receive(.init(rows: [], connectivity: .disconnected(reason: "Connection closed", isRetrying: true), generation: 3))
        #expect(!state().isEnabled)

        model.receive(.init(rows: [], connectivity: .connected, generation: 4))
        #expect(state().isEnabled)
        #expect(state().isProminent)
        #expect(state().help == "⌘T")
    }
}
