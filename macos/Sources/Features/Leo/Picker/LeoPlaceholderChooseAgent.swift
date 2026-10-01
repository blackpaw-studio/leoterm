import Foundation

/// Whether the placeholder's "Choose Agent…" can be pressed, and its
/// tooltip. While the feed is disconnected the palette could only show the
/// same banner, so the button is disabled and says how to get back (D-067).
/// Otherwise the tooltip is the menu item's live `shortcut` (B-080), and
/// there is none when the item has no shortcut. The disconnected tooltip
/// names Agents ▸ Reconnect's live `reconnectShortcut` the same way (B-104).
struct LeoPlaceholderChooseAgent: Equatable {
    let isEnabled: Bool
    let help: String?
    /// Drawn as the window's prominent action only while it can be pressed.
    var isProminent: Bool { isEnabled }

    init(host: LeoHostID, connectivity: LeoConnectivity, shortcut: String?, reconnectShortcut: String?) {
        if let banner = LeoDisconnectedBanner(host: host, connectivity: connectivity) {
            isEnabled = false
            help = "\(banner.title). Reconnect first\(reconnectShortcut.map { " (\($0))" } ?? "")."
        } else {
            isEnabled = true
            help = shortcut
        }
    }
}
