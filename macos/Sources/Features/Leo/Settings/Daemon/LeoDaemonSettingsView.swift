import LeoKit
import SwiftUI

/// The Daemon pane. The model is created when the pane mounts for a client (so
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
    /// The target owns it, so a restart started from another pane's prompt is waited out there.
    @ObservedObject private var service: LeoServiceSettingsModel

    init(target: LeoSettingsTargetModel, client: any LeoConfigClient) {
        self.target = target
        service = target.service(using: client)
        _model = StateObject(wrappedValue: LeoDaemonSettingsModel(
            client: client, revisions: target.revisions, machineHost: target.selectedHost.displayName
        ))
    }

    var body: some View {
        LeoDaemonView(
            model: model, machine: SpawnMachineOption.title(for: target.selectedHost), restart: target.restartActions, service: service
        )
        .task {
            target.register(model, for: LeoDaemonSettingsView.tab)
            await model.load()
        }
        .task { await service.load() }
        .onAppear { service.setLogVisible(isLogVisible) }
        .onChange(of: isLogVisible) { service.setLogVisible($0) }
        .onDisappear { service.setLogVisible(false) }
    }

    private var isLogVisible: Bool {
        model.isLogVisible(paneSelected: target.selectedTab == LeoDaemonSettingsView.tab)
    }
}

/// The service, web UI, remote client and remote hosts behind one segmented
/// picker. A section with unsaved edits is marked, since the others hide it.
struct LeoDaemonView: View {
    @ObservedObject var model: LeoDaemonSettingsModel
    let machine: String
    var restart = LeoConfigRestartActions.none
    /// The machine's Service model, for the Service section.
    var service: LeoServiceSettingsModel?

    var body: some View {
        VStack(spacing: 0) {
            LeoDaemonSectionPicker(model: model, web: model.web, client: model.client, hosts: model.hosts)
            Divider()
            switch model.section {
            case .service:
                if let service { LeoServiceView(model: service, machine: machine) }
            case .web:
                LeoConfigSingletonView(model: model.web, machine: machine, restart: restart)
            case .client:
                LeoConfigSingletonView(model: model.client, machine: machine, restart: restart)
            case .hosts:
                LeoConfigCollectionView(
                    model: model.hosts, machine: machine, restart: restart, extras: LeoConfigCollectionExtras(deleteNote: model.deleteNote(forHost:))
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
            Text("Service").tag(LeoDaemonSettingsModel.Section.service)
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
