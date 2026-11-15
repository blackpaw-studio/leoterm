import Foundation

/// The SF Symbols a row accessory may show. A plugin draws in the sidebar's
/// most crowded spot, so it picks from status and developer-tool glyphs
/// instead of anything in the catalog: no brand marks, nothing that reads as
/// one of Leo's own indicators (the state symbol, the unread capsule).
public enum LeoPluginSymbolAllowlist {
    public static let names: Set<String> = [
        // State
        "checkmark", "checkmark.circle", "checkmark.circle.fill", "xmark", "xmark.circle", "xmark.circle.fill",
        "exclamationmark.circle", "exclamationmark.circle.fill", "exclamationmark.triangle", "exclamationmark.triangle.fill",
        "questionmark.circle", "info.circle", "minus.circle", "plus.circle", "circle", "circle.fill", "circle.dotted",
        // Progress and time
        "clock", "clock.fill", "hourglass", "timer", "arrow.clockwise", "arrow.triangle.2.circlepath",
        "arrow.up", "arrow.down", "arrow.up.circle", "arrow.down.circle", "pause.circle", "play.circle", "stop.circle",
        "ellipsis", "ellipsis.circle",
        // Work and code
        "arrow.triangle.branch", "arrow.triangle.merge", "arrow.triangle.pull", "point.3.connected.trianglepath.dotted",
        "chevron.left.forwardslash.chevron.right", "curlybraces", "terminal", "hammer", "wrench", "gearshape", "ladybug",
        "shippingbox", "tray", "doc", "doc.text", "folder", "link", "number", "tag", "flag", "flag.fill",
        // People and signals
        "bell", "bell.fill", "bubble.left", "bubble.left.fill", "text.bubble", "person", "person.2",
        "star", "star.fill", "heart", "bolt", "bolt.fill", "lock", "lock.fill", "key", "eye", "eye.slash",
        "cloud", "network", "speedometer", "chart.bar",
    ]

    public static func isAllowed(_ name: String) -> Bool { names.contains(name) }
}
