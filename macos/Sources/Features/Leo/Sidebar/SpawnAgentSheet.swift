import AppKit
import SwiftUI

struct SpawnAgentSheet: View {
    @ObservedObject var sidebar: LeoSidebarModel
    @ObservedObject var actions: LeoAgentActions
    @StateObject private var model: SpawnAgentModel
    @Environment(\.dismiss) private var dismiss

    init(model: LeoSidebarModel, actions: LeoAgentActions) {
        sidebar = model; self.actions = actions
        _model = StateObject(wrappedValue: SpawnAgentModel(cli: actions.cliForSpawn))
    }
    var body: some View {
        Form {
            Picker("Template", selection: $model.template) { ForEach(model.templates) { Text($0.name).tag($0.name) } }
            HStack { TextField("Repository", text: $model.repo); Button("Choose…") { choose() } }
            TextField("Name", text: $model.name)
            TextField("Branch", text: $model.branch)
            TextEditor(text: $model.prompt).frame(minHeight: 80)
            if let error = model.error ?? model.validationError { Text(error).foregroundStyle(.red) }
        }
        .padding().frame(width: 440)
        .task { await model.loadTemplates() }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Spawn") { spawn() }.disabled(model.validationError != nil) } }
    }
    private func choose() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; if panel.runModal() == .OK { model.repo = panel.url?.path ?? model.repo } }
    private func spawn() {
        let request = LeoSpawnRequest(template: model.template, repo: model.repo, name: model.name.isEmpty ? nil : model.name, branch: model.branch.isEmpty ? nil : model.branch, prompt: model.prompt.isEmpty ? nil : model.prompt)
        actions.spawn(request, attach: sidebar.attachRequested, dismiss: { dismiss() })
    }
}
