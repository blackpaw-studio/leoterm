import LeoKit
import SwiftUI

/// The Tasks tab: the model is created when the pane mounts for a client (so a
/// machine switch gets a fresh one), registered with the target for the
/// unsaved-changes and reload hooks, and loads itself.
struct LeoTasksSettingsView: View {
    static let tab = LeoSettingsTab.config("tasks")

    @ObservedObject var target: LeoSettingsTargetModel

    var body: some View {
        LeoSettingsPaneState(target: target, tab: Self.tab) { client in
            LeoTasksPane(target: target, client: client)
        }
    }
}

private struct LeoTasksPane: View {
    @ObservedObject var target: LeoSettingsTargetModel
    @StateObject private var model: LeoTasksSettingsModel

    init(target: LeoSettingsTargetModel, client: any LeoConfigClient) {
        self.target = target
        _model = StateObject(wrappedValue: LeoTasksSettingsModel(
            client: client, revisions: target.revisions, machineHost: target.selectedHost.displayName
        ))
    }

    var body: some View {
        LeoTasksView(model: model, machine: SpawnMachineOption.title(for: target.selectedHost))
            .task {
                target.register(model, for: LeoTasksSettingsView.tab)
                await model.load()
            }
    }
}
