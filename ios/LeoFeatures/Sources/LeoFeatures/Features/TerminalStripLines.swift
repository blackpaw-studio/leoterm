import Foundation

/// Which rows of the terminal screen the chat's strip shows.
public enum TerminalStripLines {
    /// How many rows the strip shows.
    public static let count = 5

    /// The last `count` rows that still hold something: an agent's screen is
    /// padded below its last line, and the strip should show text, not padding.
    /// A cell nothing was drawn in reads back as NUL, which a label treats as
    /// the end of the string, so those become spaces.
    public static func bottom(_ rows: [String], count: Int = count) -> [String] {
        let cleaned = rows.map { $0.replacingOccurrences(of: "\0", with: " ") }
        let used = cleaned.reversed().drop { $0.allSatisfy(\.isWhitespace) }.reversed()
        return Array(used.suffix(count))
    }
}
