import AppKit
import LeoKit
import SwiftUI

/// The Plugins tab. App-local: it never goes through `LeoSettingsPaneState`,
/// because nothing here lives on a machine.
struct LeoPluginsSettingsView: View {
    static let tab = LeoSettingsTab.plugins

    /// The plugin system, once the app has started it.
    let system: @MainActor () -> LeoPluginSystem?

    var body: some View {
        if let system = system() {
            LeoPluginsPane(model: LeoPluginsSettingsModel(system: system))
        } else {
            ProgressView("Starting plugins…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension LeoPluginsSettingsModel {
    convenience init(system: LeoPluginSystem) {
        self.init(
            manager: system.manager, installer: system.installFlow, updater: system.updater,
            approve: { await system.presenter.approve($0) })
    }
}

private struct LeoPluginsPane: View {
    @StateObject private var model: LeoPluginsSettingsModel

    init(model: @autoclosure @escaping () -> LeoPluginsSettingsModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.rows.isEmpty { emptyState } else { list }
            footer
        }
        .sheet(isPresented: $model.isAskingInstallSource) {
            LeoPluginInstallSourceSheet { url, ref in
                Task { await model.install(url: url, ref: ref) }
            }
        }
        .confirmationDialog(
            model.pendingUninstall.map { "Uninstall “\($0.name)”?" } ?? "Uninstall?",
            isPresented: Binding(get: { model.pendingUninstall != nil }, set: { if !$0 { model.cancelUninstall() } }),
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) { model.confirmUninstall() }
            Button("Cancel", role: .cancel) { model.cancelUninstall() }
        } message: {
            Text(model.pendingUninstall?.uninstallDetail ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("Install from URL…") { model.isAskingInstallSource = true }
            Button("Load Local Folder…", action: chooseFolder)
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
            Button("Check for Updates") { Task { await model.checkForUpdates() } }
        }
        .disabled(model.isBusy)
        .padding(12)
    }

    private var list: some View {
        List(model.rows) { row in
            LeoPluginRowView(
                row: row,
                setEnabled: { model.setEnabled(row.id, $0) },
                reenable: { model.reenable(row.id) },
                review: { Task { await model.reviewApproval(row.id) } },
                showSection: { model.showSection(row.id, section: $0) },
                uninstall: { model.requestUninstall(row.id) })
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("No plugins").font(.headline)
            Text("Install one from a git URL, or load a folder you're developing.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var footer: some View {
        switch model.message {
        case .notice(let text)?:
            Text(text).foregroundStyle(.secondary).modifier(FooterStyle())
        case .failure(let text)?:
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).modifier(FooterStyle())
        case nil:
            EmptyView()
        }
    }

    private struct FooterStyle: ViewModifier {
        func body(content: Content) -> some View {
            content.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar).textSelection(.enabled)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        panel.message = "Choose a folder that contains leo-plugin.json."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await model.loadLocalFolder(folder) }
    }
}

private struct LeoPluginRowView: View {
    let row: LeoPluginRow
    let setEnabled: (Bool) -> Void
    let reenable: () -> Void
    let review: () -> Void
    let showSection: (String) -> Void
    let uninstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Enabled", isOn: Binding(get: { row.switchIsOn }, set: setEnabled))
                .toggleStyle(.switch).labelsHidden().controlSize(.small).padding(.top, 2)
                .disabled(!row.canToggle)
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                Text(row.sourceText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(row.permissionsSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                status
                ForEach(row.hiddenSections, id: \.self) { section in
                    HStack(spacing: 6) {
                        Text("“\(section)” is hidden").font(.caption).foregroundStyle(.secondary)
                        Button("Show") { showSection(section) }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            Spacer(minLength: 8)
            if row.canUninstall {
                Button(role: .destructive, action: uninstall) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Uninstall “\(row.name)”").accessibilityLabel("Uninstall \(row.name)")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(row.name).font(.headline)
            Text(row.shortSHA.map { "\(row.version) · \($0)" } ?? row.version)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if row.isDev {
                Text("DEV").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: Capsule()).foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Development plugin")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch row.status {
        case .running, .off:
            EmptyView()
        case .needsApproval(let lines):
            notice("Needs approval", detail: lines.joined(separator: " · "), symbol: "exclamationmark.shield.fill", tint: .orange) {
                Button("Review…", action: review)
            }
        case .crashDisabled(let reason):
            notice("Turned off after repeated crashes", detail: reason, symbol: "exclamationmark.triangle.fill", tint: .red) {
                Button("Re-enable", action: reenable)
            }
        case .restarting(let reason):
            notice("Restarting", detail: reason, symbol: "arrow.clockwise", tint: .secondary) { EmptyView() }
        case .refused(let reason):
            notice("Can't run", detail: reason, symbol: "xmark.octagon.fill", tint: .red) { EmptyView() }
        }
    }

    private func notice<Action: View>(
        _ title: String, detail: String, symbol: String, tint: Color, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.bold())
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            action().controlSize(.small)
        }
        .padding(.top, 2)
    }
}

/// Asks for the git URL and an optional branch or tag.
private struct LeoPluginInstallSourceSheet: View {
    let install: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var ref = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install from URL").font(.headline)
            Form {
                TextField("Git URL", text: $url, prompt: Text("https://github.com/owner/repo"))
                TextField("Branch or tag", text: $ref, prompt: Text("Default branch"))
            }
            Text("Leo downloads the plugin and shows what it asks for. Nothing runs until you approve.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue") {
                    install(url.trimmingCharacters(in: .whitespacesAndNewlines), ref.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
