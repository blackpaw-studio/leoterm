import AppKit
import SwiftUI

/// The Hosts editor sheet (spec §3.2 "Hosts"): sidebar list of hosts +
/// detail form for the selected one, standard macOS sheet chrome. Opened
/// from the host picker's "Manage Hosts…" entry.
struct LeoHostsSheet: View {
    @ObservedObject var model: LeoHostsSheetModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                hostList
                Divider()
                detail
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 380)
    }

    private var hostList: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedID) {
                ForEach(model.hosts) { host in
                    Text(host.name.isEmpty ? "Untitled" : host.name)
                        .tag(host.id as LeoHostConfiguration.ID?)
                }
            }
            .listStyle(.sidebar)
            HStack(spacing: 4) {
                Button(action: model.addHost) { Image(systemName: "plus") }
                    .accessibilityLabel("Add host")
                Button(action: model.removeSelected) { Image(systemName: "minus") }
                    .accessibilityLabel("Remove host")
                    .disabled(model.selectedID == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(width: 160)
    }

    @ViewBuilder private var detail: some View {
        if let host = model.selectedHost {
            LeoHostFormView(model: model, host: host)
        } else {
            Text("Select or add a host")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if let saveError = model.saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { if model.save() { dismiss() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isValid)
        }
        .padding()
    }
}

/// The detail form for a single host: name, SSH target, identity file
/// (with a "Choose…" `NSOpenPanel` button), remote leo path, remote socket
/// path -- plus inline validation messages.
private struct LeoHostFormView: View {
    @ObservedObject var model: LeoHostsSheetModel
    let host: LeoHostConfiguration

    var body: some View {
        Form {
            Section {
                TextField("Name", text: binding(\.name, host.name))
                TextField("SSH Target", text: binding(\.sshTarget, host.sshTarget), prompt: Text("user@host[:port]"))
                LabeledContent("Identity File") {
                    HStack {
                        TextField("", text: binding(\.identityFile, host.identityFile ?? ""), prompt: Text("optional"))
                        Button("Choose…") { chooseIdentityFile() }
                    }
                }
                TextField("Remote Leo Path", text: binding(\.remoteLeoPath, host.remoteLeoPath), prompt: Text("~/.local/bin/leo"))
                TextField("Remote Socket Path", text: binding(\.remoteSocketPath, host.remoteSocketPath), prompt: Text("~/.leo/state/leo.sock"))
                    .help("The daemon's unix socket on the remote host. A leading \"~/\" is expanded on the remote to its own $HOME; anything else must already be an absolute remote path.")
            }
            if !model.errors(for: host).isEmpty {
                Section {
                    ForEach(model.errors(for: host), id: \.self) { message in
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ keyPath: KeyPath<LeoHostConfiguration, String>, _ current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { newValue in
                model.updateSelected { existing in
                    LeoHostConfiguration(
                        id: existing.id,
                        name: keyPath == \.name ? newValue : existing.name,
                        sshTarget: keyPath == \.sshTarget ? newValue : existing.sshTarget,
                        identityFile: keyPath == \.identityFile ? newValue : existing.identityFile,
                        remoteLeoPath: keyPath == \.remoteLeoPath ? newValue : existing.remoteLeoPath,
                        remoteSocketPath: keyPath == \.remoteSocketPath ? newValue : existing.remoteSocketPath
                    )
                }
            }
        )
    }

    private func binding(_ keyPath: KeyPath<LeoHostConfiguration, String?>, _ current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { newValue in
                model.updateSelected { existing in
                    LeoHostConfiguration(
                        id: existing.id,
                        name: existing.name,
                        sshTarget: existing.sshTarget,
                        identityFile: newValue.isEmpty ? nil : newValue,
                        remoteLeoPath: existing.remoteLeoPath,
                        remoteSocketPath: existing.remoteSocketPath
                    )
                }
            }
        )
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")

        // Window-modal (`beginSheetModal`), not app-modal (`runModal`): a
        // sheet-on-a-sheet should only block the Hosts editor window, not
        // the whole app.
        guard let window = NSApp.keyWindow else {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            applyIdentityFile(url)
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            applyIdentityFile(url)
        }
    }

    private func applyIdentityFile(_ url: URL) {
        model.updateSelected { existing in
            LeoHostConfiguration(
                id: existing.id, name: existing.name, sshTarget: existing.sshTarget,
                identityFile: url.path, remoteLeoPath: existing.remoteLeoPath, remoteSocketPath: existing.remoteSocketPath
            )
        }
    }
}
