/// B-059: a keyboard move between the sidebar's rows, the old tab shortcuts
/// remapped (D-098): ⌘1–⌘8, ⌘9 (last), ⌃Tab and ⌃⇧Tab.
enum LeoRowMove: Equatable, Sendable {
    /// The Nth row, counting from 1.
    case number(Int)
    case last
    case next
    case previous
}

enum LeoRowNavigation {
    /// Where `move` lands in `rows` (display order) from `selected`. A
    /// number past the end lands on the last row, as Ghostty's `goto_tab:N`
    /// does. Next and previous wrap; with nothing selected (or a selection
    /// the list doesn't show) they land on the first and last row. `nil`
    /// when there are no rows.
    static func target<ID: Equatable>(_ move: LeoRowMove, in rows: [ID], selected: ID?) -> ID? {
        guard let last = rows.indices.last else { return nil }
        let current = selected.flatMap { rows.firstIndex(of: $0) }
        let index: Int
        switch move {
        case .number(let number): index = min(max(number - 1, 0), last)
        case .last: index = last
        case .next: index = current.map { ($0 + 1) % rows.count } ?? 0
        case .previous: index = current.map { ($0 + last) % rows.count } ?? last
        }
        return rows[index]
    }
}
