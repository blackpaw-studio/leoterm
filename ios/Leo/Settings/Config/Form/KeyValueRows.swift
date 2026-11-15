import Foundation

/// A string map as editable rows. Rows keep the order they were typed in (a
/// dictionary has none) and survive an empty or duplicate name until the
/// validator and the daemon have had their say.
struct KeyValueRows: Equatable {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    private(set) var rows: [Row]

    init(entries: [String: String]) {
        rows = Self.rows(of: entries)
    }

    /// The map the rows read as. The last of a duplicated name wins.
    var entries: [String: String] {
        Dictionary(rows.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    mutating func add() {
        rows.append(Row(key: "", value: ""))
    }

    mutating func setKey(_ key: String, at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].key = key
    }

    mutating func setValue(_ value: String, at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].value = value
    }

    mutating func remove(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    /// The map changed under the editor (a revert or a reload). Rows that
    /// already read as it stay, typed order and all.
    mutating func reset(to external: [String: String]) {
        guard external != entries else { return }
        rows = Self.rows(of: external)
    }

    private static func rows(of entries: [String: String]) -> [Row] {
        entries.sorted { $0.key < $1.key }.map { Row(key: $0.key, value: $0.value) }
    }
}
