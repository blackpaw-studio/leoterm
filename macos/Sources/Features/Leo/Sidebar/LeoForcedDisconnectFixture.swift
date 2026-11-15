#if DEBUG
import Foundation

/// DEBUG builds only: `LEO_FORCE_DISCONNECTED=1` puts the sidebar in the
/// disconnected state (D-061) once the first list of a registry connection
/// has landed, so the banner over dimmed rows can be screenshotted without
/// stopping the real daemon or a tunnel. Retry then reconnects normally.
enum LeoForcedDisconnectFixture {
    static let environmentKey = "LEO_FORCE_DISCONNECTED"
    static let forcedReason = "Forced by LEO_FORCE_DISCONNECTED"

    static func reason(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[environmentKey] == "1" ? forcedReason : nil
    }

    /// The fixture's own drop, which is never retried automatically so its
    /// banner stays up; the header's Reconnect still works.
    static func isForced(_ connectivity: LeoConnectivity) -> Bool {
        if case .disconnected(forcedReason, _) = connectivity { return true }
        return false
    }

    /// Forces This Mac's feed down once. The feed itself decides when, in
    /// order with its connections (B-166): see
    /// `LeoSidebarFeed.forceDisconnectAfterFirstList`.
    @MainActor static func arm(feeds: LeoMachineFeeds, reason: String) {
        feeds.forceDisconnectAfterFirstList(.local, reason: reason)
    }
}
#endif
