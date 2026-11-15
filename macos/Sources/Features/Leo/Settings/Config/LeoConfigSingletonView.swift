import LeoKit
import SwiftUI

/// A singleton resource's pane: its schema form under a Save / Revert bar,
/// with the conflict, failure and restart notices above it.
struct LeoConfigSingletonView: View {
    @ObservedObject var model: LeoConfigSingletonModel
    let machine: String
    var restart = LeoConfigRestartActions.none

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            LeoPaneFailure(message: message) { Task { await model.load() } }
        case .loaded:
            VStack(spacing: 0) {
                LeoConfigBanners(
                    machine: machine, hasConflict: model.conflict != nil, errorMessage: model.errorMessage, warning: model.warning,
                    restartPrompt: model.restartPrompt, restart: restart,
                    reload: { Task { await model.reloadAfterConflict() } }, overwrite: { Task { await model.overwrite() } },
                    dismissError: model.dismissError, dismissRestart: model.dismissRestartPrompt
                )
                LeoSchemaForm(
                    sections: model.sections, formErrors: model.draft?.formErrors ?? [],
                    set: { model.set($0, $1) }, revert: { model.revert($0) }
                )
                Divider()
                LeoConfigSaveBar(
                    isBusy: model.isBusy, isDirty: model.isDirty, canSave: model.canSave,
                    revert: { model.revertAll() }, save: { Task { await model.save() } }
                )
            }
        }
    }
}
