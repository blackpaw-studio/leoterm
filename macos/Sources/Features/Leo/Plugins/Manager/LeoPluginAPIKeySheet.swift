import LeoKit
import SwiftUI

/// "Add API Key": Leo's own sheet for a key a plugin asked for. The plugin
/// never sees what is typed here; it gets a handle once the key is saved.
struct LeoPluginAPIKeySheet: View {
    @ObservedObject var model: LeoPluginAPIKeySheetModel
    let finish: (LeoPluginAPIKeyEntry?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add \(model.provider.label) API Key").font(.headline)
            Text(model.message).fixedSize(horizontal: false, vertical: true)
            Form {
                SecureField("API key", text: $model.key, prompt: Text("Paste the key"))
                TextField("Name", text: $model.name, prompt: Text(model.provider.label))
            }
            .formStyle(.columns)
            if let problem = model.keyProblem ?? model.nameProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            }
            Text("Leo keeps the key in your Keychain and never shows it again. To change it, remove it and add it again.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Add") { finish(model.entry()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdd)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
