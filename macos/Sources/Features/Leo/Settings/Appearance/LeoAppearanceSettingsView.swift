import SwiftUI
import LeoKit

/// The Appearance tab: the selected machine's ordered appearance rules and
/// a live preview of what each of its agents gets from the draft.
struct LeoAppearanceSettingsView: View {
    static let tab = LeoSettingsTab.config("appearance")

    @ObservedObject var target: LeoSettingsTargetModel
    /// The machine's agents as the sidebar shows them.
    let agents: @MainActor (LeoHostID) -> [LeoAgentRow]

    var body: some View {
        LeoSettingsPaneState(target: target, tab: Self.tab) { client in
            LeoAppearancePane(target: target, client: client, agents: agents)
        }
    }
}

private struct LeoAppearancePane: View {
    @ObservedObject var target: LeoSettingsTargetModel
    @StateObject private var model: LeoAppearanceSettingsModel

    init(target: LeoSettingsTargetModel, client: any LeoConfigClient, agents: @escaping @MainActor (LeoHostID) -> [LeoAgentRow]) {
        self.target = target
        let host = target.selectedHost
        _model = StateObject(wrappedValue: LeoAppearanceSettingsModel(
            client: client, revisions: target.revisions, agents: { agents(host).map(LeoAppearancePreviewAgent.init(row:)) }
        ))
    }

    private var machine: String { SpawnMachineOption.title(for: target.selectedHost) }

    var body: some View {
        content
            .task {
                target.register(model, for: LeoAppearanceSettingsView.tab)
                await model.load()
            }
            .alert("The rules changed on \(machine)", isPresented: Binding(get: { model.isConflicted }, set: { _ in })) {
                Button("Overwrite") { Task { await model.overwriteTheirs() } }
                Button("Use Theirs", role: .destructive) { model.takeTheirs() }
            } message: {
                Text("Someone saved the appearance rules since you opened them. Overwrite them with yours, or drop your edits?")
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unsupported(let version):
            LeoTooOldPaneNotice(
                machine: machine, running: version, headline: "Update leo on \(machine)",
                detail: "Agent appearance needs a newer leo on \(machine)."
            )
        case .failed(let message):
            VStack(spacing: 8) {
                Text("Couldn’t load the appearance rules").font(.headline)
                Text(message).foregroundStyle(.secondary)
                Button("Try Again") { Task { await model.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            LeoAppearanceEditor(model: model)
        }
    }
}
