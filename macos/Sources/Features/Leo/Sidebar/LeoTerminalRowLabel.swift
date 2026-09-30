import Foundation

/// B-068: how a Terminals row reads. Two shells in the same directory both
/// title themselves "~", so a row whose title an older row already shows
/// gets a quiet ordinal suffix -- "~", "~ (2)", "~ (3)" -- the way Finder
/// numbers a second "untitled folder 2". A title no other row shares reads
/// unchanged.
struct LeoTerminalRowLabel: Identifiable, Equatable, Sendable {
    /// The row's surface.
    let id: UUID
    /// The row's display title, as its terminal set it, trimmed.
    let title: String
    /// Its place among the rows showing the same title, oldest first,
    /// from 2; `nil` for the first (or only) one.
    let ordinal: Int?

    /// The suffix shown after the title, e.g. "(2)"; `nil` when none.
    var suffix: String? { ordinal.map { "(\($0))" } }

    /// The whole label, e.g. "~ (2)": VoiceOver reads this.
    var text: String { suffix.map { "\(title) \($0)" } ?? title }

    /// The row's tooltip: the whole label, suffix included (B-079).
    var help: String { text }
}

extension LeoTerminalList {
    /// Every row's label, in row order. A pure function of the rows'
    /// order and titles, so the same rows always read the same: a new
    /// shell (always listed last) never relabels an older one, and a
    /// label changes only when which rows share its title does.
    var labels: [LeoTerminalRowLabel] {
        // Trimmed, so titles that differ only in surrounding space group
        // (and read) the same.
        let titles = rows.map(\.displayTitle)
        return rows.indices.map { index in
            let place = titles[..<index].filter { $0 == titles[index] }.count + 1
            return LeoTerminalRowLabel(
                id: rows[index].id,
                title: titles[index],
                ordinal: place > 1 ? place : nil)
        }
    }
}
