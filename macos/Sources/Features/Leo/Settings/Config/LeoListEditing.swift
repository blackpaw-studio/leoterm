import Foundation

/// The rules every selectable Settings list shares: what stays selected once
/// the selected row is removed, so the bottom bar's − behaves the same in the
/// string list, the key-value list and the Appearance rules.
enum LeoListEditing {
    /// `items` without the one at `index`, and the row to select next: the one that
    /// moved into its place, else the new last row, and nothing once the list is empty.
    /// An index outside the list changes nothing.
    static func remove<Element>(at index: Int, from items: [Element]) -> (items: [Element], selection: Int?) {
        guard items.indices.contains(index) else { return (items, nil) }
        let remaining = Array(items[..<index] + items[(index + 1)...])
        return (remaining, remaining.isEmpty ? nil : min(index, remaining.count - 1))
    }

    /// `rows` without the row whose id is `id` (nil, or an id not in `rows`, removes
    /// nothing), and the id of the row to select next, chosen as `remove(at:from:)` does.
    static func remove<Row: Identifiable>(_ id: Row.ID?, from rows: [Row]) -> (rows: [Row], selection: Row.ID?) {
        guard let id, let index = rows.firstIndex(where: { $0.id == id }) else { return (rows, id) }
        let removal = remove(at: index, from: rows)
        return (removal.items, removal.selection.map { removal.items[$0].id })
    }
}
