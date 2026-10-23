import SwiftUI

/// Asks for an item name (add, rename, duplicate), checking it as it is typed.
struct LeoNameSheet: View {
    let title: String
    let confirmTitle: String
    @State var name: String
    /// The reason `name` can't be used, or nil.
    let validate: (String) -> String?
    let submit: (String) -> Void
    let cancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .focused($isFocused)
                .onSubmit(confirm)
                .frame(minWidth: 280)
            Text(error ?? " ").font(.caption).foregroundStyle(.red).accessibilityHidden(error == nil)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm).keyboardShortcut(.defaultAction).disabled(error != nil)
            }
        }
        .padding(20)
        .onAppear { isFocused = true }
    }

    /// Nothing is said before the first keystroke; an empty name just can't be sent.
    private var error: String? {
        let reason = validate(name)
        return name.isEmpty ? nil : reason
    }

    private func confirm() {
        guard validate(name) == nil else { return }
        submit(name)
    }
}
