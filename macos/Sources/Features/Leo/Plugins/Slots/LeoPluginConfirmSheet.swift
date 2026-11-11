import LeoKit
import SwiftUI

/// "<Plugin> wants to send a message": the target is fixed, the text is the
/// person's to edit. Nothing is sent until Send.
struct LeoPluginSendSheet: View {
    let draft: LeoPluginSendDraft
    let finish: (String?) -> Void
    @State private var text: String

    init(draft: LeoPluginSendDraft, finish: @escaping (String?) -> Void) {
        self.draft = draft
        self.finish = finish
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send a message to \(draft.agent.name)?").font(.headline)
            Text("\(draft.pluginName) wants to send this to \(draft.agent.name) on \(draft.agent.machine). Edit it if you like. Nothing is sent until you press Send.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minWidth: 420, minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Send") { finish(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

/// "<Plugin> wants to start an agent": every field is editable, including the machine.
struct LeoPluginSpawnSheet: View {
    let draft: LeoPluginSpawnDraft
    let finish: (LeoPluginSpawnSpec?) -> Void
    @State private var repo: String
    @State private var branch: String
    @State private var base: String
    @State private var prompt: String
    @State private var machine: String

    init(draft: LeoPluginSpawnDraft, finish: @escaping (LeoPluginSpawnSpec?) -> Void) {
        self.draft = draft
        self.finish = finish
        _repo = State(initialValue: draft.spec.repo)
        _branch = State(initialValue: draft.spec.branch)
        _base = State(initialValue: draft.spec.base ?? "")
        _prompt = State(initialValue: draft.spec.prompt)
        _machine = State(initialValue: draft.spec.machine ?? draft.machines.first ?? "")
    }

    private var isValid: Bool {
        !repo.trimmingCharacters(in: .whitespaces).isEmpty && !branch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start a new agent?").font(.headline)
            Text("\(draft.pluginName) wants to start an agent. Edit anything you like. Nothing starts until you press Start.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Repository", text: $repo)
                TextField("Branch", text: $branch)
                TextField("Base (optional)", text: $base)
                Picker("Machine", selection: $machine) {
                    ForEach(draft.machines, id: \.self) { Text($0 == "localhost" ? "This Mac" : $0).tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Prompt")
                    TextEditor(text: $prompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 100)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    finish(LeoPluginSpawnSpec(repo: repo, branch: branch, base: base.isEmpty ? nil : base, prompt: prompt, machine: machine))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}

/// The confirmation sheets as `LeoPluginConfirming`. One sheet at a time: a
/// second request waits for the first to be answered.
@MainActor final class LeoPluginSheetConfirmer: LeoPluginConfirming {
    private let presenter: LeoPluginSheetPresenter
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(presenter: LeoPluginSheetPresenter = LeoPluginSheetPresenter()) {
        self.presenter = presenter
    }

    func confirmSend(_ draft: LeoPluginSendDraft) async -> String? {
        await exclusively { await self.presenter.presentCancellable { finish in LeoPluginSendSheet(draft: draft, finish: finish) } }
    }

    func confirmSpawn(_ draft: LeoPluginSpawnDraft) async -> LeoPluginSpawnSpec? {
        await exclusively { await self.presenter.presentCancellable { finish in LeoPluginSpawnSheet(draft: draft, finish: finish) } }
    }

    private func exclusively<T>(_ body: () async -> T) async -> T {
        if isBusy { await withCheckedContinuation { waiters.append($0) } }
        isBusy = true
        defer {
            isBusy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return await body()
    }
}
