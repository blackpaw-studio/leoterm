import AppKit

/// The fixed sizes an agent row is pinned to, taken from the fonts rather
/// than constants: SF Symbols and spinners are taller than the text beside
/// them, and a tool starting or a pending action must not move the rows
/// below.
enum LeoAgentRowMetrics {
    /// Chosen so a one-line row (this plus the list's own 4pt row inset, on
    /// both sides, around the name line) measures exactly 32pt, the sidebar
    /// list's default row height. The list sizes rows it hasn't drawn yet at
    /// that height, so a quiet row of any other height grows when it is
    /// first drawn -- after the list has already clamped its scroll offset to
    /// the old end, leaving it short of the bottom (5pt measured 34pt and
    /// did exactly that after the last terminal closed).
    static let verticalPadding: CGFloat = 4
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
