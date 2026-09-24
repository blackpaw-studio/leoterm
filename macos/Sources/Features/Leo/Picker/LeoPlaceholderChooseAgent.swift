import Foundation

/// Whether the placeholder's "Choose Agent…" can be pressed, and its
/// tooltip. While the feed is disconnected the palette could only show the
/// same banner, so the button is disabled and says how to get back (D-067).
struct LeoPlaceholderChooseAgent: Equatable {
    let isEnabled: Bool
    let help: String

    init(host: LeoHostID, connectivity: LeoConnectivity) {
        if let banner = LeoDisconnectedBanner(host: host, connectivity: connectivity) {
            isEnabled = false
            help = "\(banner.title). Reconnect first (⇧⌘R)."
        } else {
            isEnabled = true
            help = "⌘T"
        }
    }
}
