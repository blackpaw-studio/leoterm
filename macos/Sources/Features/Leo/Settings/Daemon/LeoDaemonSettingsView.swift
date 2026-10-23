import LeoKit
import SwiftUI

/// The Daemon tab. The model is created when the pane mounts for a client (so
/// a machine switch gets a fresh one), registered with the target for the
/// unsaved-changes and reload hooks, and loads itself.
struct LeoDaemonSettingsView: View {
    static let tab = LeoSettingsTab.config("daemon")

    @ObservedObject var target: LeoSettingsTargetModel

    var body: some View {
        LeoSettingsPaneState(target: target, tab: Self.tab) { client in
            LeoDaemonPane(target: target, client: client)
        }
    }
}

private struct LeoDaemonPane: View {
    @ObservedObject var target: LeoSettingsTargetModel
    @StateObject private var model: LeoDaemonSettingsModel

    init(target: LeoSettingsTargetModel, client: any LeoConfigClient) {
        self.target = target
        _model = StateObject(wrappedValue: LeoDaemonSettingsModel(
            client: client, revisions: target.revisions, machineHost: target.selectedHost.displayName
        ))
    }

    var body: some View {
        LeoDaemonView(model: model, machine: SpawnMachineOption.title(for: target.selectedHost))
            .task {
                target.register(model, for: LeoDaemonSettingsView.tab)
                await model.load()
            }
    }
}

/// The web UI, remote client and remote hosts forms behind one segmented
/// picker. A section with unsaved edits is marked, since the others hide it.
struct LeoDaemonView: View {
    @ObservedObject var model: LeoDaemonSettingsModel
    let machine: String

    var body: some View {
        VStack(spacing: 0) {
            LeoDaemonSectionPicker(model: model, web: model.web, client: model.client, hosts: model.hosts)
            Divider()
            switch model.section {
            case .web:
                LeoConfigSingletonView(model: model.web, machine: machine)
            case .client:
                LeoConfigSingletonView(model: model.client, machine: machine)
            case .hosts:
                LeoConfigCollectionView(
                    model: model.hosts, machine: machine, extras: LeoConfigCollectionExtras(deleteNote: model.deleteNote(forHost:))
                )
            }
        }
    }
}

private struct LeoDaemonSectionPicker: View {
    @ObservedObject var model: LeoDaemonSettingsModel
    @ObservedObject var web: LeoConfigSingletonModel
    @ObservedObject var client: LeoConfigSingletonModel
    @ObservedObject var hosts: LeoConfigCollectionModel

    var body: some View {
        Picker("Section", selection: $model.section) {
            Text(label(web.title, dirty: web.isDirty)).tag(LeoDaemonSettingsModel.Section.web)
            Text(label(client.title, dirty: client.isDirty)).tag(LeoDaemonSettingsModel.Section.client)
            Text(label(hosts.title, dirty: hosts.hasUnsavedChanges)).tag(LeoDaemonSettingsModel.Section.hosts)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(12)
    }

    private func label(_ title: String, dirty: Bool) -> String {
        dirty ? "\(title) •" : title
    }
}
