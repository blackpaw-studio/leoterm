import SwiftUI

/// Collects spawn parameters and reports the chosen request. The caller runs
/// the spawn (so this view stays free of daemon concerns) and adds the
/// resulting cell to the board.
struct SpawnAgentSheet: View {
    @ObservedObject var store: LeoAgentStore
    let onSpawn: (AgentSpawnRequest) -> Void
    let onCancel: () -> Void

    @State private var template: String = ""
    @State private var repo: String = ""
    @State private var branch: String = ""

    /// Inline validation hint — nil when inputs are valid.
    private var validationHint: String? {
        SpawnValidation.validate(template: template, repo: repo, branch: branch)
    }

    private var canSpawn: Bool {
        !template.isEmpty && !repo.isEmpty && validationHint == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Agent").font(.headline)
            Picker("Template", selection: $template) {
                ForEach(store.templates) { t in Text(t.name).tag(t.name) }
            }
            TextField("Repo (owner/name or workspace name)", text: $repo)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Branch (optional, requires owner/repo)", text: $branch)
                // Show branch validation hint as secondary caption — not red error
                // style (reserved for server errors below).
                if !branch.isEmpty, let hint = validationHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let err = store.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Spawn") {
                    onSpawn(AgentSpawnRequest(
                        template: template, repo: repo, name: nil,
                        branch: branch.isEmpty ? nil : branch, base: nil))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSpawn)
            }
        }
        .padding(20)
        .frame(width: 360)
        .task {
            await store.refreshTemplates()
            if template.isEmpty { template = store.templates.first?.name ?? "" }
        }
    }
}
