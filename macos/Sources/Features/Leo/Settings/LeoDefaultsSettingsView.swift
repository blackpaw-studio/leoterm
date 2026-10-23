import LeoKit
import SwiftUI

/// The Defaults tab: one form for the `defaults` resource, with the harness
/// options of the harness in force and the `push` block. The model is created
/// when the pane mounts for a client (so a machine switch gets a fresh one),
/// registered with the target for the unsaved-changes and reload hooks, and
/// loads itself.
struct LeoDefaultsSettingsView: View {
    static let tab = LeoSettingsTab.config("defaults")

    @ObservedObject var target: LeoSettingsTargetModel

    var body: some View {
        LeoSettingsPaneState(target: target, tab: Self.tab) { client in
            LeoDefaultsPane(target: target, client: client)
        }
    }
}

private struct LeoDefaultsPane: View {
    @ObservedObject var target: LeoSettingsTargetModel
    @StateObject private var model: LeoConfigSingletonModel

    init(target: LeoSettingsTargetModel, client: any LeoConfigClient) {
        self.target = target
        _model = StateObject(wrappedValue: LeoConfigSingletonModel(
            resource: "defaults", client: client, revisions: target.revisions, machineHost: target.selectedHost.displayName
        ))
    }

    var body: some View {
        LeoConfigSingletonView(model: model, machine: SpawnMachineOption.title(for: target.selectedHost), restart: target.restartActions)
            .task {
                target.register(model, for: LeoDefaultsSettingsView.tab)
                await model.load()
            }
    }
}
