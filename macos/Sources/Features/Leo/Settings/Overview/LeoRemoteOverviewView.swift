import AppKit
import LeoKit
import SwiftUI

/// Settings ▸ a remote machine: the Enabled switch, the connection form with
/// Test Connection, the daemon's version, and Remove Machine…. Edits go to the
/// Machines draft and are applied by Save; removal applies at once.
struct LeoRemoteOverviewView: View {
    @ObservedObject var model: LeoMachinesSettingsModel
    @ObservedObject var target: LeoSettingsTargetModel
    /// Observed so the badge follows the live connection.
    @ObservedObject var registry: LeoMachineRegistry

    var body: some View {
        if let host = model.selectedHost {
            VStack(spacing: 0) {
                page(for: host)
                Divider()
                footer(for: host)
            }
            .alert(
                "Remove \(host.name.isEmpty ? "this machine" : "“\(host.name)”")?",
                isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.cancelRemoval() } }),
                presenting: model.pendingRemoval
            ) { id in
                // The dismiss setter above has already cleared `pendingRemoval`: act on the id this alert showed.
                Button("Remove", role: .destructive) { model.confirmRemoval(id) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Leo stops connecting to it and forgets its settings here. The machine itself isn’t changed.")
            }
        } else {
            Text("No machine selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func overview(for host: LeoHostConfiguration) -> LeoRemoteOverview {
        // The registry knows the machine by its saved name, not a draft rename.
        let live = registry.configurations.first { $0.id == host.id }
        return LeoRemoteOverview(
            host: host, status: live.flatMap { registry.status(for: .remote($0.name)) },
            isTarget: live.map { target.selectedHost == .remote($0.name) } ?? false, daemonVersion: target.daemonVersion,
            isSaved: live != nil
        )
    }

    // MARK: Page

    private func page(for host: LeoHostConfiguration) -> some View {
        let overview = overview(for: host)
        return Form {
            Section {
                LeoOverviewHeader(systemImage: "server.rack", name: overview.name, subtitle: overview.subtitle) {
                    HStack(spacing: 12) {
                        LeoConnectionBadge(status: overview.status).fixedSize()
                        HStack(spacing: 8) {
                            Text("Enabled").foregroundStyle(.secondary).accessibilityHidden(true)
                            Toggle("Enabled", isOn: Binding(get: { host.isEnabled }, set: { model.setEnabled($0, for: host.id) }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .fixedSize()
                    }
                }
                if let reason = overview.reason { LeoOverviewReason(text: reason, isProblem: overview.isEnabled && overview.isSaved) }
            }
            Section("Connection") {
                connectionFields(for: host)
                ForEach(model.errors(for: host), id: \.self) { message in
                    Text(message).font(.caption).foregroundStyle(LeoSettingsStatus.failure.color)
                }
            }
            Section {
                LeoConnectionTestSection(
                    isTesting: model.isTesting, report: model.testReport,
                    canTest: model.errors(for: host).isEmpty, test: { Task { await model.testSelected() } }
                )
            }
            Section("Daemon") {
                LabeledContent {
                    if let version = overview.version { Text("leo \(version)").foregroundStyle(.secondary) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Runs its own leo")
                        Text("Leo connects to it over SSH. Updates happen on \(overview.name).").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func connectionFields(for host: LeoHostConfiguration) -> some View {
        TextField("Name", text: field(host, read: \.name, write: { $0.replacing(name: $1) }))
        TextField(
            "SSH target", text: field(host, read: \.sshTarget, write: { $0.replacing(sshTarget: $1) }), prompt: Text("user@host[:port]")
        )
        HStack {
            TextField(
                "Identity file",
                text: field(host, read: { $0.identityFile ?? "" }, write: { $0.replacing(identityFile: .some($1.isEmpty ? nil : $1)) }),
                prompt: Text("optional")
            )
            Button("Choose…", action: chooseIdentityFile)
        }
        TextField("Remote leo path", text: field(host, read: \.remoteLeoPath, write: { $0.replacing(remoteLeoPath: $1) }))
        TextField("Remote socket path", text: field(host, read: \.remoteSocketPath, write: { $0.replacing(remoteSocketPath: $1) }))
    }

    // MARK: Footer

    private func footer(for host: LeoHostConfiguration) -> some View {
        HStack {
            Button("Remove Machine…") { model.requestRemoval(of: host.id) }
            if let error = model.saveError {
                Text(error).font(.caption).foregroundStyle(LeoSettingsStatus.failure.color).lineLimit(2)
            }
            Spacer()
            Button("Revert", action: model.revert).disabled(!model.isDirty)
            Button("Save") { model.save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isDirty || !model.isValid)
        }
        .padding(LeoSettingsMetrics.contentPadding)
    }

    // MARK: Helpers

    /// A text binding onto one field of `host`, written back through the
    /// model so an edit clears the Test Connection result.
    private func field(
        _ host: LeoHostConfiguration, read: @escaping (LeoHostConfiguration) -> String,
        write: @escaping (LeoHostConfiguration, String) -> LeoHostConfiguration
    ) -> Binding<String> {
        Binding(
            get: { model.hosts.first { $0.id == host.id }.map(read) ?? "" },
            set: { text in model.updateSelected { write($0, text) } }
        )
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        model.updateSelected { $0.replacing(identityFile: .some(path)) }
    }
}
