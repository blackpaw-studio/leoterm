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
            HStack(alignment: .top, spacing: 0) {
                rules
                Divider()
                preview.frame(width: 240)
            }
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Appearance Rules").font(.headline)
                Text("The first rule that matches sets an agent’s color or emoji, unless the agent has its own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            List {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    LeoAppearanceRuleRow(
                        number: index + 1, rule: row.rule, problem: model.problem(at: index), matchCount: model.matchCount(at: index),
                        update: { model.update(row.id, $0) }, delete: { model.delete(row.id) }
                    )
                }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                if model.rows.isEmpty {
                    Text("No rules. Agents show only the emoji and color set on them.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            footer.padding(12)
        }
    }

    private var footer: some View {
        HStack {
            Button { model.add() } label: { Label("Add Rule", systemImage: "plus") }
            if let error = model.saveError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            Button("Revert") { model.revert() }.disabled(!model.isDirty || model.isSaving)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut("s")
                .disabled(!model.canSave)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preview").font(.headline).padding(12)
            List(model.preview) { entry in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(entry.appearance?.color?.swiftUIColor ?? .clear)
                        .frame(width: LeoAgentRowMetrics.colorBarWidth, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: LeoAgentRowMetrics.emojiSpacing) {
                            if let emoji = entry.appearance?.emoji { Text(emoji).font(.callout) }
                            Text(entry.name).lineLimit(1)
                        }
                        Text(entry.source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.inset)
        }
    }
}
