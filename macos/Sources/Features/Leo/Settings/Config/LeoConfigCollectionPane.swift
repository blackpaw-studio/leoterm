import LeoKit
import SwiftUI

/// Hosts a `LeoConfigCollectionModel` for one machine: the model is created
/// when the pane mounts for a client (so a machine switch gets a fresh one),
/// registered with the target for the unsaved-changes and reload hooks, and
/// loads itself.
struct LeoConfigCollectionPane: View {
    let resource: String
    @ObservedObject var target: LeoSettingsTargetModel
    @StateObject private var model: LeoConfigCollectionModel

    init(resource: String, target: LeoSettingsTargetModel, client: any LeoConfigClient) {
        self.resource = resource
        self.target = target
        _model = StateObject(wrappedValue: LeoConfigCollectionModel(
            resource: resource, client: client, revisions: target.revisions, machineHost: target.selectedHost.displayName
        ))
    }

    var body: some View {
        LeoConfigCollectionView(model: model, machine: SpawnMachineOption.title(for: target.selectedHost))
            .task {
                target.register(model, for: .config(resource))
                await model.load()
            }
    }
}
