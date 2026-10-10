import AppKit

/// The fixed sizes an agent row is pinned to, taken from the fonts rather
/// than constants: SF Symbols and spinners are taller than the text beside
/// them, and a tool starting or a pending action must not move the rows
/// below.
enum LeoAgentRowMetrics {
    static let verticalPadding: CGFloat = 5
    static let lineSpacing: CGFloat = 2
    /// The leading symbol's column, and the gap between it and the name.
    static let symbolColumnWidth: CGFloat = 16
    static let symbolSpacing: CGFloat = 6

    /// Where the name starts, from the row's leading edge. A dispatch row's
    /// glyph sits on this column.
    static var nameColumnInset: CGFloat { symbolColumnWidth + symbolSpacing }

    /// The name's line (`.body`).
    static var nameLineHeight: CGFloat { lineHeight(.body) }

    /// Line 2 (`.caption`).
    static var detailLineHeight: CGFloat { lineHeight(.caption1) }

    static func lineHeight(_ style: NSFont.TextStyle) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: style)
        return ceil(font.ascender - font.descender + font.leading)
    }
}
