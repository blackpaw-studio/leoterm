import Foundation

/// Which rows of the terminal screen the chat's strip shows.
public enum TerminalStripLines {
    /// How many rows the strip shows.
    public static let count = 5

    /// The strip's rows from a full screen of them, top to bottom. The bottom
    /// of a Claude Code screen is chrome (its input box, status-line rows, and
    /// tmux's own status row), so this drops tmux's status row, then shows the
    /// last `count` non-blank rows above the input box's top border. With no
    /// box on screen it shows the last `count` non-blank rows instead.
    ///
    /// A cell nothing was drawn in reads back as NUL, which a label treats as
    /// the end of the string, so those become spaces.
    public static func rows(_ screen: [String], count: Int = count) -> [String] {
        let cleaned = screen.dropLast().map { $0.replacingOccurrences(of: "\0", with: " ") }
        let content = cleaned.prefix(inputBoxTop(in: cleaned) ?? cleaned.count)
        return Array(content.filter { !$0.allSatisfy(\.isWhitespace) }.suffix(count))
    }

    /// The tallest input the box is expected to grow to before it scrolls.
    private static let maxBoxInteriorRows = 8
    private static let minRuleLength = 10

    /// The index of the top border of Claude Code's input box, if one is on
    /// screen. A rounded box opens with `╭`. The plain style is a rule above
    /// and a rule below the prompt, so the box top is the last rule's
    /// predecessor, unless that is too far up to be the same box (a rule in
    /// the agent's output).
    private static func inputBoxTop(in rows: [String]) -> Int? {
        if let rounded = rows.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("╭") }) {
            return rounded
        }
        let rules = rows.indices.filter { isRule(rows[$0]) }
        guard let last = rules.last else { return nil }
        guard rules.count > 1, let previous = rules.dropLast().last, last - previous - 1 <= maxBoxInteriorRows else { return last }
        return previous
    }

    private static func isRule(_ row: String) -> Bool {
        let text = row.trimmingCharacters(in: .whitespaces)
        guard text.count >= minRuleLength else { return false }
        return text.filter { $0 == "─" || $0 == "━" }.count * 10 >= text.count * 7
    }
}
