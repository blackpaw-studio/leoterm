import LeoKit
import SwiftUI

/// The selected task's prompt file: which file, its text, and Save. The file
/// is the one the task is configured with; another or a new one is chosen here
/// but written as the task's `prompt_file`.
struct LeoTaskPromptEditor: View {
    @ObservedObject var model: LeoTasksSettingsModel
    @State private var isNamingFile = false

    var body: some View {
        let prompt = model.prompt
        VStack(spacing: 0) {
            switch prompt.phase {
            case .idle, .loading:
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                LeoPaneFailure(message: message) { Task { await model.reloadPrompt() } }
            case .unavailable(let reason):
                unavailable(reason, error: prompt.error)
            case .loaded:
                editor(prompt)
            }
        }
        .sheet(isPresented: $isNamingFile) { fileSheet }
        .alert(
            "Discard unsaved prompt text?", isPresented: Binding(get: { prompt.confirmation != nil }, set: { if !$0 { model.cancelPromptFileSwitch() } }),
            presenting: prompt.confirmation
        ) { _ in
            Button("Discard", role: .destructive) { Task { await model.confirmPromptFileSwitch() } }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            if case .switchFile(let file) = confirmation { Text("Switching to “\(file)” drops what you typed in this prompt.") }
        }
    }

    // MARK: States

    private func unavailable(_ reason: String, error: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.doc").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("This prompt file can’t be edited here").font(.headline)
            Text(reason).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Button("Choose Another File…") { isNamingFile = true }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editor(_ prompt: LeoTaskPromptState) -> some View {
        VStack(spacing: 0) {
            header(prompt)
            if prompt.conflict != nil { conflictBanner.padding(.horizontal, 12).padding(.bottom, 8) }
            if let error = prompt.error {
                LeoTaskMessageBanner(message: error, dismiss: model.dismissPromptError).padding(.horizontal, 12).padding(.bottom, 8)
            }
            TextEditor(text: Binding(get: { prompt.text }, set: { model.setPromptText($0) }))
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .padding(.horizontal, 12)
                .accessibilityLabel("Prompt text")
            saveBar(prompt)
        }
    }

    private func header(_ prompt: LeoTaskPromptState) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(prompt.document?.files ?? [], id: \.self) { file in
                    Button { Task { await model.choosePromptFile(file) } } label: {
                        if file == prompt.document?.file { Label(file, systemImage: "checkmark") } else { Text(file) }
                    }
                }
                Divider()
                Button("New or Other File…") { isNamingFile = true }
            } label: {
                Label(prompt.document?.file.isEmpty == false ? prompt.document?.file ?? "" : "No file", systemImage: "doc.text")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Prompt file")
            if prompt.document?.revision == LeoTaskPrompt.revision(of: "") {
                Text("Not created yet").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var conflictBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("This prompt changed on the machine since you opened it").font(.headline)
                Text("Reload drops your text and shows the new one. Overwrite replaces it with yours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Reload") { Task { await model.reloadPrompt() } }
            Button("Overwrite", role: .destructive) { Task { await model.overwritePrompt() } }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private func saveBar(_ prompt: LeoTaskPromptState) -> some View {
        HStack {
            if prompt.isSaving { ProgressView().controlSize(.small) }
            Spacer()
            Button("Revert") { model.revertPrompt() }.disabled(!prompt.isDirty || prompt.isSaving)
            Button("Save") { Task { await model.savePrompt() } }
                .keyboardShortcut(.defaultAction).disabled(!prompt.isDirty || prompt.isSaving || prompt.conflict != nil)
        }
        .padding(12)
    }

    private var fileSheet: some View {
        LeoNameSheet(
            title: "Prompt file", confirmTitle: "Use File", name: "", fieldLabel: "Path in the workspace",
            validate: { LeoTaskPromptFile.problem(with: $0) },
            submit: { path in isNamingFile = false; Task { await model.createPromptFile(path) } }, cancel: { isNamingFile = false }
        )
    }
}
