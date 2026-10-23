import SwiftUI

/// A string map as two columns of fields with a remove button per row. Rows
/// keep the order they were typed in (a dictionary has none) and survive an
/// empty or duplicate key until the validator and the daemon have had their say.
struct LeoKeyValueEditor: View {
    let entries: [String: String]
    let onChange: ([String: String]) -> Void

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    @State private var rows: [Row]

    init(entries: [String: String], onChange: @escaping ([String: String]) -> Void) {
        self.entries = entries
        self.onChange = onChange
        _rows = State(initialValue: Self.rows(of: entries))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField("Name", text: $row.key).labelsHidden().font(.body.monospaced())
                    TextField("Value", text: $row.value).labelsHidden()
                    Button { remove(row.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(row.key.isEmpty ? "entry" : row.key)")
                }
            }
            Button { rows.append(Row(key: "", value: "")) } label: { Label("Add", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
        }
        .onChange(of: rows) { _ in
            let edited = dictionary(of: rows)
            if edited != entries { onChange(edited) }
        }
        .onChange(of: entries) { external in
            // A revert or reload changed the map under us.
            if external != dictionary(of: rows) { rows = Self.rows(of: external) }
        }
    }

    private func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }

    private func dictionary(of rows: [Row]) -> [String: String] {
        Dictionary(rows.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    private static func rows(of entries: [String: String]) -> [Row] {
        entries.sorted { $0.key < $1.key }.map { Row(key: $0.key, value: $0.value) }
    }
}
