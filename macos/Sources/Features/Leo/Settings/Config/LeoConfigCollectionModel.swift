import Combine
import Foundation
import LeoKit

/// One collection resource's pane (templates, later tasks and environments):
/// its list, the selected item's draft, and Save / Revert against the
/// machine's config API.
///
/// The pane's state and every transition live in LeoKit
/// (`LeoConfigCollectionState`, `LeoConfigCollectionOps`), shared with iOS;
/// this model holds the state, awaits the operations inline and forwards the
/// reads the views make.
///
/// Every write carries the revision the pane read, mapped through the shared
/// `LeoConfigRevisionTracker` so another pane's write isn't a conflict. A 409
/// keeps the draft and offers Reload (rebase onto the new document) or
/// Overwrite (resend the patch with the current revision); a 422 lands on its
/// fields; a restart-needed reply raises a prompt. Add, rename, duplicate and
/// delete are offered only for the actions the schema lists, and only while
/// the draft is clean.
@MainActor final class LeoConfigCollectionModel: ObservableObject, LeoSettingsPane {
    typealias Phase = LeoConfigCollectionState.Phase
    typealias Confirmation = LeoConfigCollectionState.Confirmation
    typealias Conflict = LeoConfigCollectionState.Conflict

    let resourceKey: String

    @Published private(set) var state: LeoConfigCollectionState

    private var client: any LeoConfigClient
    private let revisions: LeoConfigRevisionTracker

    /// A pane that edits more than the form (the task prompt) reports its
    /// unsaved state here, so leaving the item asks about it too.
    var extraUnsavedChanges: () -> Bool = { false }
    /// Called when the user chooses to drop the pane's unsaved edits.
    var onDiscard: () -> Void = {}
    /// A pane's veto over the form's Save (it asks the user first); false stops the write.
    var beforeSave: (LeoConfigDraft) -> Bool = { _ in true }

    init(
        resource: String, client: any LeoConfigClient, revisions: LeoConfigRevisionTracker,
        references: [String: [String]] = [:], machineHost: String? = nil
    ) {
        resourceKey = resource
        self.client = client
        self.revisions = revisions
        state = LeoConfigCollectionState(resource: resource, references: references, machineHost: machineHost)
    }

    // MARK: Reading state

    var phase: Phase { state.phase }
    var items: [LeoConfigItem] { state.items }
    var selection: String? { state.selection }
    var draft: LeoConfigDraft? { state.draft }
    var conflict: Conflict? { state.conflict }
    var restartPrompt: LeoConfigRestartRequired? { state.restartPrompt }
    /// The daemon saved but its reload failed.
    var warning: String? { state.warning }
    /// A failure that belongs to no field.
    var errorMessage: String? { state.errorMessage }
    var confirmation: Confirmation? { state.confirmation }
    var isBusy: Bool { state.isBusy }

    var title: String { state.title }
    var actions: Set<LeoConfigAction> { state.actions }
    var isDirty: Bool { state.isDirty }
    var canSave: Bool { state.canSave }
    var canRestructure: Bool { state.canRestructure }
    var sections: [LeoConfigFormSection] { state.sections }
    var webLink: URL? { state.webLink }

    func nameError(_ name: String, excluding: String? = nil) -> String? {
        state.nameError(name, excluding: excluding)
    }

    // MARK: LeoSettingsPane

    var hasUnsavedChanges: Bool { state.hasUnsavedChanges(extra: extraUnsavedChanges()) }

    func discardChanges() {
        state.discardEdits()
        onDiscard()
    }

    /// The machine reconnected: read again through its new client and keep the
    /// user's edits over the fresh document.
    func reload(using client: any LeoConfigClient) async {
        self.client = client
        guard state.schema != nil else { return await load() }
        state.dismissConflict()
        await refresh(preferring: selection, carrying: draft)
    }

    // MARK: Loading

    func load() async {
        state.beginLoading()
        state.loaded(await LeoConfigCollectionOps.load(resource: resourceKey, client: client, references: state.references))
    }

    private func refresh(preferring name: String?, carrying carried: LeoConfigDraft?) async {
        do {
            state.apply(try await client.collection(resourceKey), preferring: name, carrying: carried)
        } catch {
            state.report(error)
        }
    }

    // MARK: Editing

    func set(_ path: String, _ value: LeoConfigValue) {
        state.set(path, value)
    }

    func revert(_ path: String) {
        state.revert(path)
    }

    func revertAll() {
        state.revertAll()
    }

    func select(_ name: String?) {
        state.requestSelect(name, extraUnsaved: extraUnsavedChanges())
    }

    // MARK: Saving

    func save() async {
        guard canSave, let draft, let name = selection, beforeSave(draft) else { return }
        let sent = draft
        await write(
            ifMatch: revisions.resolve(draft.revision), preferring: name, onFailure: { model, error in model.state.failed(error, sent: sent) },
            operation: { [resourceKey, client] ifMatch in
                try await client.update(resourceKey, name: name, patch: sent.patch, ifMatch: ifMatch)
            }
        )
    }

    /// Reload after a conflict: the new document, with the user's edits over it.
    func reloadAfterConflict() async {
        guard conflict != nil else { return }
        state.dismissConflict()
        await refresh(preferring: selection, carrying: draft)
    }

    /// Overwrite after a conflict: the item is read again, the user's edits
    /// (per key, per env entry, and a list as the names it added and removed)
    /// are replayed over that copy, and the result is sent against its
    /// revision. Another writer's list entries and keys survive; nothing is
    /// sent when their copy already has every edit.
    func overwrite() async {
        guard let (stale, name) = state.beginOverwrite() else { return }
        let outcome = await LeoConfigCollectionOps.overwrite(
            stale: stale, resource: resourceKey, name: name, client: client, revisions: revisions
        )
        state.finishOverwrite(outcome, name: name)
    }

    // MARK: Add, rename, duplicate, delete

    /// `values` carries the fields an add requires beyond the name (a task's schedule).
    func add(name: String, values: [String: LeoConfigValue] = [:]) async {
        guard state.allows(.add) else { return }
        await write(ifMatch: revisions.resolve(state.revision), preferring: name, selectingResult: true) { [resourceKey, client] ifMatch in
            try await client.add(resourceKey, name: name, values: values, ifMatch: ifMatch)
        }
    }

    /// A write of `patch` to one item that isn't the open form's Save (a list
    /// toggle, a prompt file choice): only these keys are sent, the open
    /// draft and its edits stay, and a stale revision is retried once against
    /// the current one, because the patch is the user's whole intent. That
    /// retry doesn't vouch for the open form: its edits stay on the revision
    /// they were made against, so its Save still meets the other writer's
    /// change as a conflict. Returns why it failed, or nil.
    func applyPatch(_ patch: [String: LeoConfigValue], to name: String) async -> String? {
        guard phase == .loaded, !isBusy else { return "Another change is still being saved. Try again in a moment." }
        var failure: String?
        await write(
            ifMatch: revisions.resolve(state.revision), preferring: selection, keepingDraft: true, retryingConflict: true,
            onFailure: { _, error in failure = LeoConfigCollectionState.message(for: error) },
            operation: { [resourceKey, client] ifMatch in
                try await client.update(resourceKey, name: name, patch: patch, ifMatch: ifMatch)
            }
        )
        return failure
    }

    func rename(to newName: String) async {
        guard state.allows(.rename), let name = selection else { return }
        await write(ifMatch: revisions.resolve(state.revision), preferring: newName) { [resourceKey, client] ifMatch in
            try await client.rename(resourceKey, name: name, to: newName, ifMatch: ifMatch)
        }
    }

    func duplicate(as newName: String) async {
        guard state.allows(.duplicate), let name = selection else { return }
        await write(ifMatch: revisions.resolve(state.revision), preferring: newName, selectingResult: true) { [resourceKey, client] ifMatch in
            try await client.duplicate(resourceKey, name: name, as: newName, ifMatch: ifMatch)
        }
    }

    func requestDelete() {
        state.requestDelete(selection)
    }

    private func deleteSelected(_ name: String) async {
        await write(ifMatch: revisions.resolve(state.revision), preferring: nil) { [resourceKey, client] ifMatch in
            try await client.delete(resourceKey, name: name, ifMatch: ifMatch)
        }
    }

    // MARK: Confirmations and banners

    /// Takes the confirmation the alert showed: SwiftUI has already closed the
    /// alert, and cleared `confirmation`, by the time its button runs.
    func confirm(_ pending: Confirmation) async {
        switch state.take(pending) {
        case .delete(let name):
            await deleteSelected(name)
        case .discard(let target):
            discardChanges()
            state.selectNow(target)
        }
    }

    func cancelConfirmation() {
        state.cancelConfirmation()
    }

    func dismissRestartPrompt() {
        state.dismissRestartPrompt()
    }

    func dismissError() {
        state.dismissError()
    }

    // MARK: Writing

    /// Runs one write, then reads the list again. `preferring` is the item to
    /// select afterwards; `selectingResult` follows the item the daemon
    /// returned; `keepingDraft` rebases the open draft onto what was read, but
    /// only a draft whose base is the revision this write was sent with: one
    /// left behind by an earlier retry keeps its own, however many writes follow. The write's failure goes to `onFailure`, else to the banner.
    private func write(
        ifMatch: String, preferring name: String?, selectingResult: Bool = false, keepingDraft: Bool = false, retryingConflict: Bool = false,
        onFailure: ((LeoConfigCollectionModel, Error) -> Void)? = nil,
        operation: @Sendable (String) async throws -> LeoConfigWriteResult
    ) async {
        guard state.beginWrite() else { return }
        let outcome = await LeoConfigCollectionOps.write(
            resource: resourceKey, client: client, revisions: revisions, ifMatch: ifMatch, retryingConflict: retryingConflict,
            draftRevision: draft?.revision, operation: operation
        )
        guard let error = state.finishWrite(outcome, preferring: name, selectingResult: selectingResult, keepingDraft: keepingDraft) else { return }
        if let onFailure { onFailure(self, error) } else { state.report(error) }
    }
}
