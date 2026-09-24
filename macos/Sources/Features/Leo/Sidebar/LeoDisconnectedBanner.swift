import Foundation

/// The words of the sidebar's disconnected banner (D-061), shared with
/// the agent palette. The reason may be a remote ssh's stderr, so it goes
/// through the one sanitizer (B-020) here, when rendered.
struct LeoDisconnectedBanner: Equatable {
    let title: String
    let reason: String
    let isRetrying: Bool

    init?(host: LeoHostID, connectivity: LeoConnectivity) {
        guard case .disconnected(let reason, let isRetrying) = connectivity else { return nil }
        title = "Disconnected from \(LeoSFTPServerText.sanitized(host.displayName))"
        self.reason = LeoSFTPServerText.sanitized(reason)
        self.isRetrying = isRetrying
    }
}
