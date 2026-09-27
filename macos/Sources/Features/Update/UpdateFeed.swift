import Foundation

/// Sparkle appcast location for Leo builds.
///
/// Upstream Ghostty serves separate tip/stable appcasts from its own CDN.
/// Leo publishes a single appcast as a GitHub release asset, so every
/// `auto-update-channel` value resolves to the same feed.
enum UpdateFeed {
    static let leoAppcast = "https://github.com/blackpaw-studio/leoterm/releases/latest/download/appcast.xml"

    static func urlString(for channel: Ghostty.AutoUpdateChannel) -> String {
        switch channel {
        case .tip, .stable: return leoAppcast
        }
    }
}
