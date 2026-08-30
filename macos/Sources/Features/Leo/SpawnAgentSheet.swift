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

    init(
        store: LeoAgentStore,
        prefill: AgentSnapshot? = nil,
        onSpawn: @escaping (AgentSpawnRequest) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
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

    /// Hint shown only under the branch field — restricted to branch-specific
    /// problems. Shown only when both fields are non-empty and repo is not in
    /// owner/name form (the condition that makes a branch invalid).
    private var branchValidationHint: String? {
        guard !branch.isEmpty, !repo.isEmpty, !SpawnValidation.isGitHubRepo(repo) else { return nil }
        return SpawnValidation.validate(template: template, repo: repo, branch: branch)
    }

    private var canSpawn: Bool {
        !template.isEmpty && validationHint == nil
    }

    /// Reason the Spawn button is disabled, surfaced as a tooltip. `nil` when
    /// spawning is allowed.
    private var spawnDisabledReason: String? {
        SpawnValidation.disabledReason(template: template, repo: repo, branch: branch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Agent").font(.headline)
            if store.templates.isEmpty {
                Text("No templates found").foregroundStyle(.secondary).font(.callout)
            } else {
                Picker("Template", selection: $template) {
                    ForEach(store.templates) { t in Text(t.name).tag(t.name) }
                }
            }
            TextField("Repo (owner/name or workspace name)", text: $repo)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Branch (optional, requires owner/repo)", text: $branch)
                // Show branch-specific hint as secondary caption — not red error
                // style (reserved for server errors below). The repo-required
                // message is intentionally excluded here; it belongs to the repo
                // field, not the branch field.
                if let hint = branchValidationHint {
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
                .help(spawnDisabledReason ?? "")
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
