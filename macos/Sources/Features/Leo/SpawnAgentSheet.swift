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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Agent").font(.headline)
            Picker("Template", selection: $template) {
                ForEach(store.templates) { t in Text(t.name).tag(t.name) }
            }
            TextField("Repo (owner/name or workspace name)", text: $repo)
            TextField("Branch (optional, requires owner/repo)", text: $branch)
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
                .disabled(template.isEmpty || repo.isEmpty)
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
