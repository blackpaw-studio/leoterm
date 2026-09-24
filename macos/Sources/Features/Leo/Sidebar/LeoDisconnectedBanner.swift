import Foundation

/// The words of the sidebar's disconnected banner (D-061), shared with
/// the agent palette. The reason may be a remote ssh's stderr, so it goes
/// through the one sanitizer (B-020) here, when rendered.
struct LeoDisconnectedBanner: Equatable {
    let title: String
    let reason: String
    let isRetrying: Bool
    /// One line, tail-truncated: a long reason (an identifier, a path)
    /// would otherwise wrap mid-word in the narrow sidebar (B-038).
    let reasonLineLimit = 1
    /// The whole (sanitized) reason, for the truncated line's tooltip.
    var reasonHelp: String { reason }

    init?(host: LeoHostID, connectivity: LeoConnectivity) {
        guard case .disconnected(let reason, let isRetrying) = connectivity else { return nil }
        title = "Disconnected from \(LeoSFTPServerText.sanitized(host.displayName))"
        self.reason = LeoSFTPServerText.sanitized(reason)
        self.isRetrying = isRetrying
    }
}
