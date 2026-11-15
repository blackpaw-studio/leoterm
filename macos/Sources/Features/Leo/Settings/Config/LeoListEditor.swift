import SwiftUI

/// An ordered list of strings: one field per entry with a remove button, and
/// an add button underneath.
struct LeoListEditor: View {
    let items: [String]
    let onChange: ([String]) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("", text: Binding(get: { items[index] }, set: { replace(index, with: $0) }))
                        .labelsHidden()
                    Button { remove(index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove entry \(index + 1)")
                }
            }
            Button { onChange(items + [""]) } label: { Label("Add", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
        }
    }

    private func replace(_ index: Int, with text: String) {
        guard items.indices.contains(index) else { return }
        var updated = items
        updated[index] = text
        onChange(updated)
    }

    private func remove(_ index: Int) {
        guard items.indices.contains(index) else { return }
        var updated = items
        updated.remove(at: index)
        onChange(updated)
    }
}
