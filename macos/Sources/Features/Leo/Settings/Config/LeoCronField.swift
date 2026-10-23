import LeoKit
import SwiftUI

/// A cron expression with the daemon's reading of it underneath.
struct LeoCronField: View {
    let text: Binding<String>
    let preview: LeoCronPreviewResult?
    let prompt: Text?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField("", text: text, prompt: prompt).labelsHidden().font(.body.monospaced()).multilineTextAlignment(.trailing)
            switch preview {
            case .valid(let description)?:
                Text(description).font(.caption).foregroundStyle(.secondary)
            case .invalid(let reason)?:
                Text(reason).font(.caption).foregroundStyle(.red).accessibilityLabel("Error: \(reason)")
            case nil:
                EmptyView()
            }
        }
    }
}
