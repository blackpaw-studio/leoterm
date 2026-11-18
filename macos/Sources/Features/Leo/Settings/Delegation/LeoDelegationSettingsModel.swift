import Combine
import Foundation
import LeoKit

/// The Delegation pane: the role × profile matrix, the active profile, the
/// enabled switch, the hide list, and role and profile structure.
///
/// The pane's state and every transition live in LeoKit
/// (`LeoDelegationPaneState`, `LeoDelegationOps`), shared with iOS; this
/// model holds the state, awaits the operations inline and forwards the
/// reads the views make.
///
/// Every write carries `If-Match`. A write of what the user typed (a cell, a
/// description, the hide list) is sent against the revision that edit was
/// based on, with only the edited keys laid over what is current, and a 409
/// keeps the edit and offers Reload (the edit rebased onto the new document)
/// or Overwrite (the same edit over a fresh read). A single-key write beside
/// an open edit (the enabled switch) rebases that edit only when the edit's
/// base is the revision the write was sent with, so a write that had to retry
/// against another writer's revision never hides that writer's change from an
/// edit's own Save. Structure waits for clean forms.
@MainActor final class LeoDelegationSettingsModel: ObservableObject, LeoSettingsPane {
    typealias Phase = LeoDelegationPaneState.Phase

    @Published private(set) var state: LeoDelegationPaneState

    private var client: any LeoConfigClient
    private let revisions: LeoConfigRevisionTracker
    private var previewToken: UUID?

    init(client: any LeoConfigClient, revisions: LeoConfigRevisionTracker, machineHost: String? = nil) {
        self.client = client
        self.revisions = revisions
        state = LeoDelegationPaneState(machineHost: machineHost)
    }

    // MARK: Reading state

    var phase: Phase { state.phase }
    var document: LeoDelegationDocument? { state.document }
    var matrix: LeoDelegationMatrix { state.matrix }
    var cellEditor: LeoDelegationCellEditor? { state.cellEditor }
    var useForEditor: LeoDelegationUseForEditor? { state.useForEditor }
    var hiddenAgentsEdit: LeoDelegationHiddenAgentsEdit? { state.hiddenAgentsEdit }
    var preview: LeoDelegationPreviewState? { state.preview }
    var confirmation: LeoDelegationConfirmation? { state.confirmation }
    var conflict: LeoDelegationConflict? { state.conflict }
    var restartPrompt: LeoConfigRestartRequired? { state.restartPrompt }
    /// The daemon saved but its reload failed.
    var warning: String? { state.warning }
    /// A failure that belongs to no field.
    var errorMessage: String? { state.errorMessage }
    var isBusy: Bool { state.isBusy }

    var isConfigured: Bool { state.isConfigured }
    var warnings: [String] { state.warnings }
    var recentConsults: [LeoDelegationConsult] { state.recentConsults }
    var templates: [LeoDelegationTemplate] { state.templates }
    /// The switch as it reads now: the value being written until the daemon answers.
    var displayedEnabled: Bool { state.displayedEnabled }
    var hiddenAgentNames: [String] { state.hiddenAgentNames }
    var hiddenAgentsAreDefault: Bool { state.hiddenAgentsAreDefault }
    var webLink: URL? { state.webLink }
    var canWrite: Bool { state.canWrite }
    /// Structural changes wait for clean forms, so no edit is lost to a rename.
    var canRestructure: Bool { state.canRestructure }

    func canDeleteRole(_ name: String) -> Bool { state.canDeleteRole(name) }
    func canDeleteProfile(_ name: String) -> Bool { state.canDeleteProfile(name) }
    func canActivate(_ profile: String) -> Bool { state.canActivate(profile) }
    func roleNameError(_ name: String, excluding: String? = nil) -> String? { state.roleNameError(name, excluding: excluding) }
    func profileNameError(_ name: String, excluding: String? = nil) -> String? { state.profileNameError(name, excluding: excluding) }

    // MARK: LeoSettingsPane

    var hasUnsavedChanges: Bool { state.hasUnsavedChanges }

    func discardChanges() {
        state.discardChanges()
    }

    /// The machine reconnected: read again through its new client and keep the
    /// user's edits over the fresh document.
    func reload(using client: any LeoConfigClient) async {
        self.client = client
        guard document != nil else { return await load() }
        state.dismissConflict()
        await readRebasingAll()
    }

    // MARK: Loading

    func load() async {
        state.beginLoading()
        state.loaded(await LeoDelegationOps.load(client: client))
    }

    private func readRebasingAll() async {
        do {
            state.adopt(try await client.delegation(), rebasing: Set(LeoDelegationEditor.allCases))
        } catch {
            state.report(error)
        }
    }

    // MARK: Cell editing

    func beginCellEdit(profile: String, role: String) { state.beginCellEdit(profile: profile, role: role) }
    func setCellTemplate(_ template: String) { state.setCellTemplate(template) }
    func setCellModel(_ model: String) { state.setCellModel(model) }
    func setCellEffort(_ effort: String) { state.setCellEffort(effort) }

    /// Closes the popover of that cell. A late close of another cell's popover leaves the open editor alone.
    func cancelCellEdit(profile: String, role: String) {
        state.cancelCellEdit(profile: profile, role: role)
    }

    func saveCellEdit() async {
        guard let editor = cellEditor, editor.edit.isDirty else { return }
        await write(.cell)
    }

    // MARK: Description editing

    func beginUseForEdit(role: String) { state.beginUseForEdit(role: role) }
    func setUseForText(_ text: String) { state.setUseForText(text) }
    func cancelUseForEdit(role: String) { state.cancelUseForEdit(role: role) }

    func saveUseFor() async {
        guard useForEditor?.isDirty == true else { return }
        await write(.useFor)
    }

    // MARK: Hidden agents

    func setHiddenAgents(_ names: [String]) { state.setHiddenAgents(names) }
    func revertHiddenAgents() { state.revertHiddenAgents() }

    func saveHiddenAgents() async {
        guard hiddenAgentsEdit?.isDirty == true else { return }
        await write(.hiddenAgents)
    }

    // MARK: Enabled

    func setEnabled(_ enabled: Bool) async {
        guard canWrite else { return }
        await write(.enabled(enabled), retryingConflict: true)
    }

    // MARK: Active profile

    /// Reads what activating `profile` would change and shows it; nothing is written.
    func requestActivate(_ profile: String) async {
        guard state.beginPreview(profile) else { return }
        let token = UUID()
        previewToken = token
        let outcome = await LeoDelegationOps.preview(profile, client: client)
        guard previewToken == token else { return }
        state.finishPreview(outcome, for: profile)
    }

    func cancelPreview() {
        previewToken = nil
        state.cancelPreview()
    }

    func confirmActivate() async {
        guard let operation = state.confirmActivate() else { return }
        previewToken = nil
        await write(operation)
    }

    // MARK: Roles and profiles

    func addRole(name: String, template: String) async {
        guard canRestructure else { return }
        await write(.addRole(name: name, template: template))
    }

    func renameRole(_ name: String, to newName: String) async {
        guard canRestructure else { return }
        await write(.renameRole(name, to: newName))
    }

    func requestDeleteRole(_ name: String) { state.requestDeleteRole(name) }

    func addProfile(name: String) async {
        guard canRestructure else { return }
        await write(.addProfile(name))
    }

    func renameProfile(_ name: String, to newName: String) async {
        guard canRestructure else { return }
        await write(.renameProfile(name, to: newName))
    }

    func duplicateProfile(_ name: String, as newName: String) async {
        guard canRestructure else { return }
        await write(.duplicateProfile(name, as: newName))
    }

    func requestDeleteProfile(_ name: String) { state.requestDeleteProfile(name) }

    /// Takes the confirmation the alert showed: SwiftUI has already closed it,
    /// and cleared the state, by the time its button runs.
    func confirm(_ pending: LeoDelegationConfirmation) async {
        guard let operation = state.take(pending) else { return }
        await write(operation)
    }

    func cancelConfirmation() { state.cancelConfirmation() }

    // MARK: Conflicts and banners

    /// Reload after a conflict: the new document, with the user's edits over it.
    func reloadAfterConflict() async {
        guard state.beginReload() else { return }
        await readRebasingAll()
    }

    /// Overwrite after a conflict: the same write, with the user's edits laid
    /// over a fresh read of the document and sent against its revision.
    func overwrite() async {
        guard let pending = conflict else { return }
        await write(pending.operation, overwriting: true)
    }

    func dismissRestartPrompt() { state.dismissRestartPrompt() }
    func dismissError() { state.dismissError() }

    // MARK: Writing

    private func write(_ operation: LeoDelegationOperation, retryingConflict: Bool = false, overwriting: Bool = false) async {
        guard let document, state.beginWrite(operation) else { return }
        let outcome = await LeoDelegationOps.write(
            operation, edits: state.edits, document: document, client: client, revisions: revisions,
            retryingConflict: retryingConflict, overwriting: overwriting
        )
        state.finishWrite(outcome)
    }
}
