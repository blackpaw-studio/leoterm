import Combine
import AppKit
import SwiftUI
import LeoKit

struct SpawnAgentSheet: View {
    @ObservedObject var sidebar: LeoSidebarModel
    @ObservedObject var actions: LeoAgentActions
    private let attach: (LeoAgentRow, AttachDisposition) -> Void
    @StateObject private var model: SpawnAgentModel
    @Environment(\.dismiss) private var dismiss

    private let chooseDirectory: () -> String?

    /// `context`: the machine "New Agent Here" was opened from, which the
    /// Machine field starts on when it's reachable. `source`: B-176's "New
    /// Agent in Worktree…" -- the row's template, machine and owner/repo
    /// prefilled, the machine locked, and a required new branch.
    init(model: LeoSidebarModel, actions: LeoAgentActions, context: LeoHostID? = nil, source: LeoAgentRow? = nil,
         attach: @escaping (LeoAgentRow, AttachDisposition) -> Void,
         memory: SpawnMachineMemory = SpawnMachineMemory(defaults: .standard),
         chooseDirectory: @escaping () -> String? = SpawnAgentSheet.openPanel) {
        sidebar = model; self.actions = actions; self.attach = attach
        _model = StateObject(wrappedValue: SpawnAgentModel(
            source: source, context: context, lastUsed: memory.lastUsed,
            feeds: .live(sidebar: model, actions: actions), remember: memory.remember
        ))
        self.chooseDirectory = chooseDirectory
    }
    var body: some View {
        Form {
            if let source = model.source { worktreeHeader(source) }
            machineField
            Picker("Template", selection: $model.template) {
                Text("Choose a template").tag("")
                ForEach(model.templates) { Text($0.name).tag($0.name) }
            }
            if let source = model.source {
                worktreeFields(source)
            } else {
                LabeledContent("Repository") {
                    HStack {
                        TextField("", text: $model.repo)
                        Button("Choose…") { choose() }.disabled(!model.canBrowseRepository)
                    }
                }
            }
            TextField("Name", text: $model.name)
            if !model.isWorktree { TextField("Branch", text: $model.branch) }
            if model.showsEnvironments { environmentsField }
            TextEditor(text: $model.prompt).frame(minHeight: 80)
            if let error = model.error ?? model.templateError ?? model.validationError { Text(error).foregroundStyle(.red) }
        }
        .padding().frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Create") { spawn() }.disabled(model.validationError != nil || model.isSpawning) }
        }
    }
    /// Unreachable machines are listed, dimmed, with why; a worktree spawn
    /// shows its source's machine and can't change it.
    private var machineField: some View {
        Picker("Machine", selection: Binding(get: { model.machine }, set: { host in
            model.choose(host)
            // A pick the model rejected leaves `machine` unchanged and so
            // publishes nothing: re-read it so the popup snaps back.
            model.objectWillChange.send()
        })) {
            ForEach(model.machineOptions) { option in
                Text(option.detail.map { "\(option.title)  —  \($0)" } ?? option.title)
                    .tag(option.host)
                    .disabled(!option.isSelectable)
            }
        }
        .disabled(model.isMachineLocked)
    }
    /// B-283: prefilled from the template's default; sent only when edited.
    private var environmentsField: some View {
        LabeledContent("Environments") {
            VStack(alignment: .leading, spacing: 2) {
                LeoEnvironmentListEditor(list: Binding(get: { model.environments }, set: { model.editEnvironments($0) }), available: model.environmentCatalog.catalog?.names ?? [])
                if case .failed(let message) = model.environmentCatalog {
                    Text("Environments unavailable: \(message)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func worktreeHeader(_ source: LeoAgentRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("New Agent in Worktree").font(.headline)
            Text("A new branch of \(source.name)'s repository.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    /// Repository is the source agent's, read-only: the spawn runs on its
    /// machine's daemon against that owner/repo.
    @ViewBuilder private func worktreeFields(_ source: LeoAgentRow) -> some View {
        LabeledContent("Repository") { Text(model.repo).textSelection(.enabled) }
        VStack(alignment: .leading, spacing: 2) {
            TextField("Branch", text: $model.branch, prompt: Text("feature/my-change"))
            Text("New branch from origin's default branch").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose() {
        if let path = chooseDirectory() { model.repo = path }
    }
    private func spawn() {
        model.spawn(model.request(), actions: actions, attach: attach, dismiss: { dismiss() })
    }

    private static func openPanel() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
