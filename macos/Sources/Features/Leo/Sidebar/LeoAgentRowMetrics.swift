import AppKit

/// The fixed heights an agent row's lines are pinned to, taken from the
/// fonts rather than constants: SF Symbols and spinners are taller than the
/// text beside them, and a tool starting or a pending action must not move
/// the rows below.
enum LeoAgentRowMetrics {
    static let verticalPadding: CGFloat = 7
    static let lineSpacing: CGFloat = 4
    static let pillHorizontalPadding: CGFloat = 6
    static let pillVerticalPadding: CGFloat = 2
    static let pillSymbolSpacing: CGFloat = 3

    /// The name's line (`.body`).
    static var nameLineHeight: CGFloat { lineHeight(.body) }

    /// A pill: its text's line plus the padding above and below.
    static var pillHeight: CGFloat { lineHeight(.caption2) + 2 * pillVerticalPadding }

    /// Line 2: the taller of the pill and the `.caption` detail text.
    static var detailLineHeight: CGFloat { max(pillHeight, lineHeight(.caption1)) }

    static func lineHeight(_ style: NSFont.TextStyle) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: style)
        return ceil(font.ascender - font.descender + font.leading)
    }
}
