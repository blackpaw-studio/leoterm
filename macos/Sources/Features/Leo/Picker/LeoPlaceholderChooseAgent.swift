import Foundation
import LeoKit

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
        self.init(machines: [(host, connectivity)], shortcut: shortcut, reconnectShortcut: reconnectShortcut)
    }

    /// Every shown machine, This Mac first (Q3): enabled while any machine
    /// is connected; otherwise This Mac's state decides.
    init(machines: [(host: LeoHostID, connectivity: LeoConnectivity)], shortcut: String?, reconnectShortcut: String?) {
        let anyConnected = machines.contains { $0.connectivity == .connected }
        if !anyConnected, let deciding = machines.first, let banner = LeoDisconnectedBanner(host: deciding.host, connectivity: deciding.connectivity) {
            isEnabled = false
            help = "\(banner.title). Reconnect first\(reconnectShortcut.map { " (\($0))" } ?? "")."
        } else {
            isEnabled = true
            help = shortcut
        }
    }
}
