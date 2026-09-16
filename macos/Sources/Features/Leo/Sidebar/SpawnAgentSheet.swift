import AppKit
import SwiftUI

struct SpawnAgentSheet: View {
    @ObservedObject var sidebar: LeoSidebarModel
    @ObservedObject var actions: LeoAgentActions
    private let attach: (LeoAgentRow, AttachDisposition) -> Void
    @StateObject private var model: SpawnAgentModel
    @Environment(\.dismiss) private var dismiss

    private let chooseDirectory: () -> String?

    init(model: LeoSidebarModel, actions: LeoAgentActions, attach: @escaping (LeoAgentRow, AttachDisposition) -> Void,
         chooseDirectory: @escaping () -> String? = SpawnAgentSheet.openPanel) {
        sidebar = model; self.actions = actions; self.attach = attach
        _model = StateObject(wrappedValue: SpawnAgentModel(cli: actions.cliForSpawn))
        self.chooseDirectory = chooseDirectory
    }
    var body: some View {
        Form {
            Picker("Template", selection: $model.template) {
                Text("Choose a template").tag("")
                ForEach(model.templates) { Text($0.name).tag($0.name) }
            }
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
    private func choose() {
        if let path = chooseDirectory() { model.repo = path }
    }
    private func spawn() {
        let request = LeoSpawnRequest(template: model.template, repo: model.repo, name: model.name.isEmpty ? nil : model.name, branch: model.branch.isEmpty ? nil : model.branch, prompt: model.prompt.isEmpty ? nil : model.prompt)
        actions.spawn(request, attach: attach, dismiss: { dismiss() }, failure: model.setError)
    }

    private static func openPanel() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
