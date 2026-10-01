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

    // MARK: Palette (B-041)

    /// The palette's disconnected row is the sidebar banner itself, so its
    /// reason gets the same one line + full-text tooltip.
    @Test func thePalettesDisconnectedRowCarriesTheBannersOneLineReason() throws {
        let raw = "LEO_FORCE_DISCONNECTED=1 forced this state after the first list\nfor screenshots"
        let model = LeoAgentPaletteModel()
        model.update(
            snapshot: LeoSidebarSnapshot(rows: [], connectivity: .disconnected(reason: raw, isRetrying: false), generation: 1),
            selectedHost: .remote("mars"),
            hostState: .connected(socketPath: "/tmp/leo.sock")
        )
        guard case .disconnected(let banner) = model.rows.first else {
            Issue.record("expected the disconnected row first, got \(model.rows)")
            return
        }
        let sidebar = try #require(LeoDisconnectedBanner(host: .remote("mars"), connectivity: .disconnected(reason: raw, isRetrying: false)))
        #expect(banner == sidebar)
        #expect(banner.title == "Disconnected from mars")
        #expect(banner.reasonLineLimit == 1)
        #expect(banner.reasonHelp == LeoSFTPServerText.sanitized(raw))
        #expect(model.confirm() == nil)
    }

    // MARK: Choose Agent…

    @Test func chooseAgentIsEnabledWithItsShortcutAsHelpWhileConnected() {
        let state = LeoPlaceholderChooseAgent(host: .local, connectivity: .connected, shortcut: "⌘O", reconnectShortcut: "⇧⌘R")
        #expect(state.isEnabled)
        #expect(state.isProminent)
        #expect(state.help == "⌘O")
    }

    @Test func chooseAgentIsDisabledWhileDisconnectedAndSaysHowToReconnect() {
        let state = LeoPlaceholderChooseAgent(host: .remote("mars"), connectivity: .disconnected(reason: "ssh exited (255)", isRetrying: false), shortcut: "⌘O", reconnectShortcut: "⇧⌘R")
        #expect(!state.isEnabled)
        #expect(!state.isProminent)
        #expect(state.help == "Disconnected from mars. Reconnect first (⇧⌘R).")
    }

    /// B-104: the "how to reconnect" names Agents ▸ Reconnect's live
    /// shortcut, and drops it rather than guess when Reconnect has none.
    @Test func theDisconnectedHelpNamesReconnectsLiveShortcut() {
        let disconnected = LeoConnectivity.disconnected(reason: "x", isRetrying: false)
        let rebound = LeoPlaceholderChooseAgent(host: .local, connectivity: disconnected, shortcut: "⌘O", reconnectShortcut: "⌥⌘R")
        let unbound = LeoPlaceholderChooseAgent(host: .local, connectivity: disconnected, shortcut: "⌘O", reconnectShortcut: nil)

        #expect(rebound.help == "Disconnected from localhost. Reconnect first (⌥⌘R).")
        #expect(unbound.help == "Disconnected from localhost. Reconnect first.")
    }

    /// B-080: with Choose Agent… unbound the tooltip is left out, not a
    /// stale "⌘O".
    @Test func chooseAgentHasNoHintWithoutAShortcut() {
        let state = LeoPlaceholderChooseAgent(host: .local, connectivity: .connected, shortcut: nil, reconnectShortcut: "⇧⌘R")
        #expect(state.isEnabled)
        #expect(state.help == nil)
    }

    /// Only a disconnected feed disables it: loading and failed states have
    /// their own panels, and the palette explains them.
    @Test func chooseAgentStaysEnabledOutsideTheDisconnectedState() {
        #expect(LeoPlaceholderChooseAgent(host: .local, connectivity: .loading, shortcut: "⌘O", reconnectShortcut: "⇧⌘R").isEnabled)
        #expect(LeoPlaceholderChooseAgent(host: .local, connectivity: .failed(message: "x"), shortcut: "⌘O", reconnectShortcut: "⇧⌘R").isEnabled)
        #expect(!LeoPlaceholderChooseAgent(host: .local, connectivity: .disconnected(reason: "x", isRetrying: true), shortcut: "⌘O", reconnectShortcut: "⇧⌘R").isEnabled)
    }

    /// Follows the sidebar model's snapshots: connect → disconnect → reconnect.
    @Test func chooseAgentFollowsTheFeedAcrossConnectDisconnectReconnect() {
        let model = LeoSidebarModel()
        func state() -> LeoPlaceholderChooseAgent {
            LeoPlaceholderChooseAgent(host: .local, connectivity: model.snapshot.connectivity, shortcut: "⌘O", reconnectShortcut: "⇧⌘R")
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
        #expect(state().help == "⌘O")
    }
}
