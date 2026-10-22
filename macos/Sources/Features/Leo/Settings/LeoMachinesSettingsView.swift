import AppKit
import LeoKit
import SwiftUI

/// Settings ▸ Machines: the machine list with enable toggles, the edit form
/// with Test Connection, Revert and Save, and the Stats style control.
struct LeoMachinesSettingsView: View {
    @ObservedObject var model: LeoMachinesSettingsModel
    @ObservedObject var statsStyle: LeoStatsStyleSetting
    /// Observed only so the list's status dots follow the live connections.
    @ObservedObject var registry: LeoMachineRegistry

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                machineList
                Divider()
                detail
            }
            Divider()
            LeoStatsStyleSection(setting: statsStyle)
        }
        .frame(minWidth: 780, minHeight: 600)
    }

    // MARK: List

    private var machineList: some View {
        VStack(spacing: 0) {
            thisMacRow
            List(selection: $model.selectedID) {
                ForEach(model.hosts) { host in
                    LeoMachineListRow(
                        host: host,
                        status: registry.status(for: .remote(host.name)),
                        setEnabled: { model.setEnabled($0, for: host.id) }
                    )
                    .tag(host.id as LeoHostConfiguration.ID?)
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 4) {
                Button(action: model.addHost) { Image(systemName: "plus") }
                    .accessibilityLabel("Add machine")
                Button(action: model.removeSelected) { Image(systemName: "minus") }
                    .accessibilityLabel("Remove machine")
                    .disabled(model.selectedID == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 240)
    }

    /// This Mac is always there and always on: nothing to edit.
    private var thisMacRow: some View {
        HStack(spacing: 8) {
            LeoStatusDot(status: registry.status(for: .local))
            VStack(alignment: .leading, spacing: 1) {
                Text("This Mac").fontWeight(.medium)
                Text("Local daemon socket").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Always on")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let host = model.selectedHost {
            VStack(alignment: .leading, spacing: 16) {
                form(for: host)
                LeoConnectionTestSection(
                    isTesting: model.isTesting, report: model.testReport,
                    canTest: model.errors(for: host).isEmpty, test: { Task { await model.testSelected() } }
                )
                Spacer(minLength: 0)
                footer
            }
            .padding(20)
        } else {
            VStack {
                Spacer()
                Text("No machine selected").foregroundStyle(.secondary)
                Spacer()
                footer.padding(20)
            }
        }
    }

    private func form(for host: LeoHostConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Form {
                TextField("Name", text: field(host, read: \.name, write: { $0.replacing(name: $1) }))
                TextField(
                    "SSH Target", text: field(host, read: \.sshTarget, write: { $0.replacing(sshTarget: $1) }),
                    prompt: Text("user@host[:port]")
                )
                HStack {
                    TextField(
                        "Identity File",
                        text: field(host, read: { $0.identityFile ?? "" }, write: { $0.replacing(identityFile: .some($1.isEmpty ? nil : $1)) }),
                        prompt: Text("optional")
                    )
                    Button("Choose…", action: chooseIdentityFile)
                }
                TextField("Remote Leo Path", text: field(host, read: \.remoteLeoPath, write: { $0.replacing(remoteLeoPath: $1) }))
                TextField(
                    "Remote Socket Path", text: field(host, read: \.remoteSocketPath, write: { $0.replacing(remoteSocketPath: $1) })
                )
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            ForEach(model.errors(for: host), id: \.self) { message in
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let error = model.saveError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            Button("Revert", action: model.revert).disabled(!model.isDirty)
            Button("Save") { model.save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isDirty || !model.isValid)
        }
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

private struct LeoMachineListRow: View {
    let host: LeoHostConfiguration
    let status: LeoMachineStatus?
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            LeoStatusDot(status: host.isEnabled ? status : .disabled)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name.isEmpty ? "Untitled" : host.name).fontWeight(.medium)
                Text(host.sshTarget).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(host.isEnabled ? 1 : 0.55)
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { host.isEnabled }, set: setEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct LeoStatusDot: View {
    let status: LeoMachineStatus?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch status {
        case .connected?: .green
        case .failed?: .red
        case .connecting?: .yellow
        case .disabled?, nil: .gray.opacity(0.5)
        }
    }

    private var label: String {
        switch status {
        case .connected?: "Connected"
        case .failed?: "Unreachable"
        case .connecting?: "Connecting"
        case .disabled?: "Disabled"
        case nil: "Not connected"
        }
    }
}
