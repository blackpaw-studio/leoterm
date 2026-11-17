import SwiftUI

/// An ordered list of strings: one field per entry in a selectable list, with
/// the standard bottom bar to add an entry or remove the selected one.
struct LeoListEditor: View {
    let items: [String]
    let onChange: ([String]) -> Void

    @State private var selection: Int?

    var body: some View {
        LeoEmbeddedList(rowCount: items.count, selection: $selection, remove: removeSelected, emptyLabel: "No entries") {
            ForEach(items.indices, id: \.self) { index in
                TextField("", text: Binding(get: { items.indices.contains(index) ? items[index] : "" }, set: { replace(index, with: $0) }))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                    .accessibilityLabel("Entry \(index + 1)")
            }
        } add: {
            LeoBarAddButton(label: "Add entry") {
                onChange(items + [""])
                selection = items.count
            }
        }
        .onChange(of: items.count) { count in
            if let current = selection, current >= count { selection = nil }
        }
    }

    private func replace(_ index: Int, with text: String) {
        guard items.indices.contains(index) else { return }
        var updated = items
        updated[index] = text
        onChange(updated)
    }

    private func removeSelected() {
        guard let selection else { return }
        let removal = LeoListEditing.remove(at: selection, from: items)
        onChange(removal.items)
        self.selection = removal.selection
    }
}
