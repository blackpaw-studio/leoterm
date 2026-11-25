import Combine
import Foundation
import LeoKit

/// One singleton resource's form (defaults, web, client): the document, its
/// draft, and Save / Revert against the machine's config API.
///
/// The form's state and every transition live in LeoKit
/// (`LeoConfigSingletonState`, `LeoConfigSingletonOps`), shared with iOS;
/// this model holds the state, awaits the operations inline and forwards the
/// reads the views make.
///
/// It follows the collection model's rules. Every write carries the revision
/// the form was read at, mapped through the shared revision tracker so
/// another pane's write isn't a conflict, and sends only the keys the user
/// changed. A 409 keeps the draft and offers Reload (the user's edits over the
/// new document) or Overwrite (the same edits over the file as it is now,
/// read again first, so another writer's list entries and keys survive); a
/// 422 lands on its fields; a restart-needed reply raises a prompt. Edits made
/// while a save is in flight stay in the form.
@MainActor final class LeoConfigSingletonModel: ObservableObject, LeoSettingsPane {
    typealias Phase = LeoConfigSingletonState.Phase
    typealias Conflict = LeoConfigSingletonState.Conflict

    let resourceKey: String

    @Published private(set) var state: LeoConfigSingletonState

    private var client: any LeoConfigClient
    private let revisions: LeoConfigRevisionTracker
    /// Adjusts the daemon's description of the resource (a string field the
    /// app draws as a pick from another collection).
    private let resourceTransform: (LeoConfigResource) -> LeoConfigResource

    init(
        resource: String, client: any LeoConfigClient, revisions: LeoConfigRevisionTracker, references: [String: [String]] = [:],
        machineHost: String? = nil, resourceTransform: @escaping (LeoConfigResource) -> LeoConfigResource = { $0 }
    ) {
        resourceKey = resource
        self.client = client
        self.revisions = revisions
        self.resourceTransform = resourceTransform
        state = LeoConfigSingletonState(resource: resource, references: references, machineHost: machineHost)
    }

    // MARK: Reading state

    var phase: Phase { state.phase }
    var draft: LeoConfigDraft? { state.draft }
    var conflict: Conflict? { state.conflict }
    var restartPrompt: LeoConfigRestartRequired? { state.restartPrompt }
    /// The daemon saved but its reload failed.
    var warning: String? { state.warning }
    /// A failure that belongs to no field.
    var errorMessage: String? { state.errorMessage }
    var isBusy: Bool { state.isBusy }

    var title: String { state.title }
    var isDirty: Bool { state.isDirty }
    var canSave: Bool { state.canSave }
    var sections: [LeoConfigFormSection] { state.sections }
    var webLink: URL? { state.webLink }

    /// The names behind a reference field changed (a host was added): the form
    /// offers them and judges the open edit against them.
    func setReferences(_ new: [String: [String]]) {
        state.setReferences(new)
    }

    // MARK: LeoSettingsPane

    var hasUnsavedChanges: Bool { isDirty }

    func discardChanges() {
        state.revertAll()
    }

    /// The machine reconnected: read again through its new client and keep the
    /// user's edits over the fresh document.
    func reload(using client: any LeoConfigClient) async {
        self.client = client
        guard state.schema != nil else { return await load() }
        state.dismissConflict()
        await refresh()
    }

    // MARK: Loading

    func load() async {
        state.beginLoading()
        var load = await LeoConfigSingletonOps.load(resource: resourceKey, client: client, references: state.references)
        load.schema = load.schema?.transforming(resourceKey, resourceTransform)
        state.loaded(load)
    }

    /// Reads the document again and carries the open draft over it.
    private func refresh() async {
        do {
            state.apply(try await client.document(resourceKey), carrying: draft)
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

    // MARK: Saving

    func save() async {
        guard canSave, let sent = draft, state.beginWrite() else { return }
        let outcome = await LeoConfigSingletonOps.write(resource: resourceKey, client: client, revisions: revisions, sent: sent)
        if let error = state.finishWrite(outcome) { state.failed(error, sent: sent) }
    }

    /// Save for a control that applies as it flips (a switch): when the write
    /// fails outright (not a conflict, which keeps the edit for Reload or
    /// Overwrite), the edit is dropped and the machine's value read again, so
    /// the control never shows what the machine doesn't hold. The error stays.
    func saveDiscardingOnFailure() async {
        await save()
        guard isDirty, conflict == nil else { return }
        let message = errorMessage
        state.revertAll()
        await refresh()
        if let message { state.report(FailureMessage(text: message)) }
    }

    private struct FailureMessage: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// Reload after a conflict: the new document, with the user's edits over it.
    func reloadAfterConflict() async {
        guard conflict != nil else { return }
        state.dismissConflict()
        await refresh()
    }

    /// Overwrite after a conflict: the user's edits replayed over the file as
    /// it is now, then sent against that revision. A list the edit added to
    /// keeps what the other writer put in it.
    func overwrite() async {
        guard let stale = state.beginOverwrite() else { return }
        let outcome = await LeoConfigSingletonOps.overwrite(stale: stale, resource: resourceKey, client: client, revisions: revisions)
        state.finishOverwrite(outcome)
    }

    // MARK: Banners

    func dismissRestartPrompt() {
        state.dismissRestartPrompt()
    }

    func dismissError() {
        state.dismissError()
    }
}
