import LeoKit
import SwiftUI

/// The Delegation tab: the model is created when the pane mounts for a client
/// (so a machine switch gets a fresh one), registered with the target for the
/// unsaved-changes and reload hooks, and loads itself.
struct LeoDelegationSettingsView: View {
    static let tab = LeoSettingsTab.config("delegation")

    @ObservedObject var target: LeoSettingsTargetModel

    var body: some View {
        LeoSettingsPaneState(target: target, tab: Self.tab) { client in
            LeoDelegationPane(target: target, client: client)
        }
    }
}

private struct LeoDelegationPane: View {
    @ObservedObject var target: LeoSettingsTargetModel
    @StateObject private var model: LeoDelegationSettingsModel

    init(target: LeoSettingsTargetModel, client: any LeoConfigClient) {
        self.target = target
        _model = StateObject(wrappedValue: LeoDelegationSettingsModel(
            client: client, revisions: target.revisions, machineHost: target.selectedHost.displayName
        ))
    }

    var body: some View {
        LeoDelegationView(model: model, machine: SpawnMachineOption.title(for: target.selectedHost), restart: target.restartActions)
            .task {
                target.register(model, for: LeoDelegationSettingsView.tab)
                await model.load()
            }
    }
}
