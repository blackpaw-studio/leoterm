import SwiftUI

/// B-177: Rename… on a terminal row's context menu. Prefilled with the
/// row's title; its placeholder reads the terminal's own title, which an
/// empty name restores. A SwiftUI sheet like the agent rename, not
/// Ghostty's Change Terminal Title alert: a hidden shell has no window to
/// put that on.
struct LeoTerminalRenameSheet: View {
    static let footnote = "Leave blank to use the terminal\u{2019}s own title."

    /// The row's title as it reads now (no "(2)" suffix).
    let currentTitle: String
    /// The terminal's own title, under any name the row was given.
    let liveTitle: String
    let rename: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(currentTitle: String, liveTitle: String, rename: @escaping (String) -> Void) {
        self.currentTitle = currentTitle
        self.liveTitle = liveTitle
        self.rename = rename
        _name = State(initialValue: currentTitle)
    }

    /// What Rename hands on: `nil` when the name is left as it was, so
    /// confirming the prefilled title doesn't pin a title the terminal
    /// would have changed.
    static func submission(name: String, currentTitle: String) -> String? {
        name == currentTitle ? nil : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Terminal").font(.headline)
            TextField(liveTitle, text: $name)
            Text(Self.footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    Self.submission(name: name, currentTitle: currentTitle).map(rename)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
