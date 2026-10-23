import LeoKit
import SwiftUI

/// The popover a cell opens: template, model override and effort, with Save and
/// Cancel. Clearing the template deletes the cell, and says so.
struct LeoDelegationCellPopover: View {
    static let knownEfforts = ["low", "medium", "high", "xhigh", "max"]

    @ObservedObject var model: LeoDelegationSettingsModel

    var body: some View {
        if let editor = model.cellEditor {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(editor.role) in \(editor.profile)").font(.headline)
                field("Template", error: editor.errors["template"]) {
                    Picker("Template", selection: Binding(get: { editor.edit.target.template }, set: model.setCellTemplate)) {
                        Text("Not routed").tag("")
                        ForEach(templateNames(including: editor.edit.target.template), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                field("Model", error: editor.errors["model"], help: "Empty uses the template’s model.") {
                    TextField(inheritedModel(editor) ?? "model", text: Binding(get: { editor.edit.target.model }, set: model.setCellModel))
                        .textFieldStyle(.roundedBorder).labelsHidden().disabled(editor.edit.deletesCell)
                }
                field("Effort", error: editor.errors["effort"], help: "Empty uses the harness’s default.") {
                    HStack(spacing: 6) {
                        TextField("effort", text: Binding(get: { editor.edit.target.effort }, set: model.setCellEffort))
                            .textFieldStyle(.roundedBorder).labelsHidden().disabled(editor.edit.deletesCell)
                        Menu {
                            Button("Default") { model.setCellEffort("") }
                            ForEach(Self.knownEfforts, id: \.self) { effort in Button(effort) { model.setCellEffort(effort) } }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                        }
                        .menuStyle(.borderlessButton).fixedSize().disabled(editor.edit.deletesCell).accessibilityLabel("Effort choices")
                    }
                }
                if let formError = editor.errors[""] {
                    Text(formError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if editor.edit.deletesCell, editor.edit.isDirty {
                    Label("Saving removes this role from \(editor.profile).", systemImage: "trash").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancelCellEdit(profile: editor.profile, role: editor.role) }
                        .keyboardShortcut(.cancelAction)
                    Button(editor.edit.deletesCell ? "Remove" : "Save") { Task { await model.saveCellEdit() } }
                        .keyboardShortcut(.defaultAction).disabled(!editor.edit.isDirty || model.isBusy)
                }
            }
            .padding(16).frame(width: 320)
        }
    }

    private func field<Content: View>(_ title: String, error: String?, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let help {
                Text(help).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// Every template, plus the cell's own when the machine no longer lists it.
    private func templateNames(including current: String) -> [String] {
        let names = model.templates.map(\.name)
        return current.isEmpty || names.contains(current) ? names : names + [current]
    }

    private func inheritedModel(_ editor: LeoDelegationCellEditor) -> String? {
        model.templates.first { $0.name == editor.edit.target.template }?.model
    }
}

/// The popover for a role's description: one write of `use_for`.
struct LeoDelegationUseForPopover: View {
    @ObservedObject var model: LeoDelegationSettingsModel

    var body: some View {
        if let editor = model.useForEditor {
            VStack(alignment: .leading, spacing: 10) {
                Text("What \(editor.role) is for").font(.headline)
                TextField("Use for…", text: Binding(get: { editor.text }, set: model.setUseForText), axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder).frame(width: 300)
                if let error = editor.error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancelUseForEdit(role: editor.role) }.keyboardShortcut(.cancelAction)
                    Button("Save") { Task { await model.saveUseFor() } }
                        .keyboardShortcut(.defaultAction).disabled(!editor.isDirty || model.isBusy)
                }
            }
            .padding(16)
        }
    }
}
