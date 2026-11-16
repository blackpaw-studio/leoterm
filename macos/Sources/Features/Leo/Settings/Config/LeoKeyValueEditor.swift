import LeoKit
import SwiftUI

/// A string map as two columns of fields in a selectable list, with the standard
/// bottom bar to add a variable or remove the selected one. Rows
/// keep the order they were typed in (a dictionary has none) and survive an
/// empty or duplicate key until the validator and the daemon have had their say.
/// `secrets` are variables whose value the daemon holds back: each is listed
/// with Replace and Clear, and kept as it is when the map is saved otherwise.
struct LeoKeyValueEditor: View {
    let entries: [String: String]
    var secrets: [String: LeoConfigSecretState] = [:]
    var setSecret: (String, LeoConfigValue) -> Void = { _, _ in }
    let onChange: ([String: String]) -> Void

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    @State private var rows: [Row]
    @State private var selection: UUID?

    init(
        entries: [String: String], secrets: [String: LeoConfigSecretState] = [:],
        setSecret: @escaping (String, LeoConfigValue) -> Void = { _, _ in }, onChange: @escaping ([String: String]) -> Void
    ) {
        self.entries = entries
        self.secrets = secrets
        self.setSecret = setSecret
        self.onChange = onChange
        _rows = State(initialValue: Self.rows(of: entries))
    }

    var body: some View {
        LeoEmbeddedList(rowCount: secrets.count + rows.count, selection: $selection, remove: removeSelected, emptyLabel: "No variables") {
            ForEach(secrets.keys.sorted(), id: \.self) { name in
                // Held-back values are listed but never selected: they are replaced or
                // cleared in place, not removed here. The same two flexible columns as a
                // plain row, so names and values line up down the list.
                HStack(spacing: 6) {
                    Text(name).font(.body.monospaced()).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LeoSecretField(
                        state: secrets[name] ?? .set, confirmClearOf: name,
                        set: { setSecret(name, $0) }, revert: { setSecret(name, .secret(isSet: true)) }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField("Name", text: $row.key).labelsHidden().font(.body.monospaced())
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(maxWidth: .infinity)
                    TextField("Value", text: $row.value).labelsHidden()
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
        } add: {
            LeoBarAddButton(label: "Add variable") {
                let row = Row(key: "", value: "")
                rows.append(row)
                selection = row.id
            }
        }
        .onChange(of: rows) { _ in
            if let current = selection, !rows.contains(where: { $0.id == current }) { selection = nil }
            let edited = dictionary(of: rows)
            if edited != entries { onChange(edited) }
        }
        .onChange(of: entries) { external in
            // A revert or reload changed the map under us.
            if external != dictionary(of: rows) { rows = Self.rows(of: external) }
        }
    }

    private func removeSelected() {
        let removal = LeoListEditing.remove(selection, from: rows)
        rows = removal.rows
        selection = removal.selection
    }

    private func dictionary(of rows: [Row]) -> [String: String] {
        Dictionary(rows.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    private static func rows(of entries: [String: String]) -> [Row] {
        entries.sorted { $0.key < $1.key }.map { Row(key: $0.key, value: $0.value) }
    }
}
