import SwiftUI

/// A cron expression with the daemon's reading of it underneath.
struct LeoCronField: View {
    let text: Binding<String>
    let preview: String?
    let prompt: Text?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField("", text: text, prompt: prompt).labelsHidden().font(.body.monospaced()).multilineTextAlignment(.trailing)
            if let preview {
                Text(preview).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
