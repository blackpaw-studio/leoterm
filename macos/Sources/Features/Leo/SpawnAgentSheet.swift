import SwiftUI

/// Collects spawn parameters and reports the chosen request. The caller runs
/// the spawn (so this view stays free of daemon concerns) and adds the
/// resulting cell to the board.
struct SpawnAgentSheet: View {
    @ObservedObject var store: LeoAgentStore
    let onSpawn: (AgentSpawnRequest) -> Void
    let onCancel: () -> Void

    @State private var template: String
    @State private var repo: String
    @State private var branch: String

    /// When non-nil, the sheet opens prefilled with a dead cell's last known
    /// values so the user can respawn without re-entering everything.
    private let prefill: AgentSnapshot?

    init(
        store: LeoAgentStore,
        prefill: AgentSnapshot? = nil,
        onSpawn: @escaping (AgentSpawnRequest) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.prefill = prefill
        self.onSpawn = onSpawn
        self.onCancel = onCancel
        _template = State(initialValue: prefill?.template ?? "")
        _repo = State(initialValue: prefill?.repo ?? "")
        _branch = State(initialValue: prefill?.branch ?? "")
    }

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
            if template.isEmpty {
                // No prefill: default to the first available template.
                template = store.templates.first?.name ?? ""
            } else if !store.templates.contains(where: { $0.name == template }) {
                // Prefill template no longer exists: fall back to default but
                // keep any repo that was prefilled.
                template = store.templates.first?.name ?? ""
            }
        }
    }
}
