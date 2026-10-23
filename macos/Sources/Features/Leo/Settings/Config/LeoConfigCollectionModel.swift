import Combine
import Foundation
import LeoKit

/// One collection resource's pane (templates, later tasks and environments):
/// its list, the selected item's draft, and Save / Revert against the
/// machine's config API.
///
/// Every write carries the revision the pane read, mapped through the shared
/// `LeoConfigRevisionTracker` so another pane's write isn't a conflict. A 409
/// keeps the draft and offers Reload (rebase onto the new document) or
/// Overwrite (resend the patch with the current revision); a 422 lands on its
/// fields; a restart-needed reply raises a prompt. Add, rename, duplicate and
/// delete are offered only for the actions the schema lists, and only while
/// the draft is clean.
@MainActor final class LeoConfigCollectionModel: ObservableObject, LeoSettingsPane {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// A question waiting on the user.
    enum Confirmation: Equatable {
        case delete(String)
        /// Leave the item, dropping its unsaved edits, for `thenSelect`.
        case discardChanges(thenSelect: String?)
    }

    /// The daemon's file moved on since this pane read it.
    struct Conflict: Equatable {
        let currentRevision: String
    }

    let resourceKey: String

    @Published private(set) var phase = Phase.loading
    @Published private(set) var items: [LeoConfigItem] = []
    @Published private(set) var selection: String?
    @Published private(set) var draft: LeoConfigDraft?
    @Published private(set) var conflict: Conflict?
    @Published private(set) var restartPrompt: LeoConfigRestartRequired?
    /// The daemon saved but its reload failed.
    @Published private(set) var warning: String?
    /// A failure that belongs to no field.
    @Published private(set) var errorMessage: String?
    @Published private(set) var confirmation: Confirmation?
    @Published private(set) var isBusy = false

    private var client: any LeoConfigClient
    private let revisions: LeoConfigRevisionTracker
    private var references: [String: [String]]
    private let machineHost: String?
    private var schema: LeoConfigSchema?
    private var webDocument: LeoConfigDocument?
    /// The file revision the list was read at.
    private var revision = ""

    /// A pane that edits more than the form (the task prompt) reports its
    /// unsaved state here, so leaving the item asks about it too.
    var extraUnsavedChanges: () -> Bool = { false }
    /// Called when the user chooses to drop the pane's unsaved edits.
    var onDiscard: () -> Void = {}

    init(
        resource: String, client: any LeoConfigClient, revisions: LeoConfigRevisionTracker,
        references: [String: [String]] = [:], machineHost: String? = nil
    ) {
        resourceKey = resource
        self.client = client
        self.revisions = revisions
        self.references = references
        self.machineHost = machineHost
    }

    // MARK: Reading state

    private var resource: LeoConfigResource? { schema?.resource(resourceKey) }

    var title: String { resource?.label ?? resourceKey.capitalized }
    var actions: Set<LeoConfigAction> { Set(resource?.actions ?? []) }
    /// A pane's veto over the form's Save (it asks the user first); false stops the write.
    var beforeSave: (LeoConfigDraft) -> Bool = { _ in true }

    var isDirty: Bool { draft?.isDirty ?? false }
    var canSave: Bool { draft?.canSave == true && conflict == nil && !isBusy }
    /// Structural changes wait for a clean draft, so no edit is lost to a rename.
    var canRestructure: Bool { !hasUnsavedChanges && !isBusy && phase == .loaded }

    var sections: [LeoConfigFormSection] {
        guard let draft, let resource, let schema else { return [] }
        return LeoConfigFormLayout.sections(
            resource: resource, harnesses: schema.harnesses, draft: draft, references: references, webLink: webLink
        )
    }

    var webLink: URL? {
        LeoConfigWebLink.url(web: webDocument, machineHost: machineHost, resource: resourceKey, item: selection)
    }

    func nameError(_ name: String, excluding: String? = nil) -> String? {
        validator?.nameError(name, existing: items.map(\.name), excluding: excluding)
    }

    private var validator: LeoConfigValidator? {
        guard let resource, let schema else { return nil }
        return LeoConfigValidator(resource: resource, harnesses: schema.harnesses, namePattern: schema.namePattern, references: references)
    }

    // MARK: LeoSettingsPane

    var hasUnsavedChanges: Bool { isDirty || extraUnsavedChanges() }

    func discardChanges() {
        draft?.revert()
        onDiscard()
    }

    /// The machine reconnected: read again through its new client and keep the
    /// user's edits over the fresh document.
    func reload(using client: any LeoConfigClient) async {
        self.client = client
        guard schema != nil else { return await load() }
        conflict = nil
        await refresh(preferring: selection, carrying: draft)
    }

    // MARK: Loading

    func load() async {
        phase = .loading
        do {
            schema = try await client.schema()
            webDocument = try? await client.document("web")
            await loadReferences()
            let collection = try await client.collection(resourceKey)
            apply(collection, preferring: selection, carrying: nil)
            phase = .loaded
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// The names behind the schema's reference fields (a task's template), so
    /// they pick from, and are checked against, what exists. A collection that
    /// can't be read is left unchecked: the daemon still judges.
    private func loadReferences() async {
        let wanted = Set(resource?.fields.compactMap { $0.type == .reference ? $0.references : nil } ?? [])
        for key in wanted where references[key] == nil && key != resourceKey {
            if let list = try? await client.collection(key) { references[key] = list.items.map(\.name) }
        }
    }

    private func refresh(preferring name: String?, carrying carried: LeoConfigDraft?, rebasing: Bool = true) async {
        do {
            apply(try await client.collection(resourceKey), preferring: name, carrying: carried, rebasing: rebasing)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// `rebasing: false` leaves a carried draft with edits on the document it was opened on, so its next Save is judged against that revision.
    private func apply(_ collection: LeoConfigCollection, preferring name: String?, carrying carried: LeoConfigDraft?, rebasing: Bool = true) {
        items = collection.items
        revision = collection.revision
        let chosen = [name, selection].lazy.compactMap { $0 }.first { wanted in items.contains { $0.name == wanted } } ?? items.first?.name
        selection = chosen
        guard let item = items.first(where: { $0.name == chosen }) else {
            draft = nil
            return
        }
        let fresh = LeoConfigDraft(document: document(of: item), validator: validator)
        draft = carried.flatMap { kept in
            guard kept.document.name == chosen else { return nil }
            return rebasing || !kept.isDirty ? kept.rebased(onto: fresh.document) : kept
        } ?? fresh
    }

    private func document(of item: LeoConfigItem) -> LeoConfigDocument {
        LeoConfigDocument(
            revision: revision, name: item.name, values: item.values, inherited: item.inherited, effectiveHarness: item.effectiveHarness
        )
    }

    // MARK: Editing

    func set(_ path: String, _ value: LeoConfigValue) {
        draft?.set(path, value)
    }

    func revert(_ path: String) {
        draft?.revert(path)
    }

    func revertAll() {
        draft?.revert()
        errorMessage = nil
    }

    func select(_ name: String?) {
        guard name != selection else { return }
        guard !hasUnsavedChanges else {
            confirmation = .discardChanges(thenSelect: name)
            return
        }
        selectNow(name)
    }

    private func selectNow(_ name: String?) {
        selection = name
        errorMessage = nil
        warning = nil
        conflict = nil
        guard let item = items.first(where: { $0.name == name }) else {
            draft = nil
            return
        }
        draft = LeoConfigDraft(document: document(of: item), validator: validator)
    }

    // MARK: Saving

    func save() async {
        guard canSave, let draft, let name = selection, beforeSave(draft) else { return }
        let sent = draft
        await write(
            ifMatch: revisions.resolve(draft.revision), preferring: name, onFailure: { model, error in model.handleSaveFailure(error, draft: sent) },
            operation: { [resourceKey, client] ifMatch in
                try await client.update(resourceKey, name: name, patch: sent.patch, ifMatch: ifMatch)
            }
        )
    }

    /// Reload after a conflict: the new document, with the user's edits over it.
    func reloadAfterConflict() async {
        guard conflict != nil else { return }
        conflict = nil
        await refresh(preferring: selection, carrying: draft)
    }

    /// Overwrite after a conflict: the same patch against the revision the
    /// daemon says is current.
    func overwrite() async {
        guard let conflict, let draft, let name = selection else { return }
        let sent = draft
        await write(
            ifMatch: conflict.currentRevision, preferring: name, onFailure: { model, error in model.handleSaveFailure(error, draft: sent) },
            operation: { [resourceKey, client] ifMatch in
                try await client.update(resourceKey, name: name, patch: sent.patch, ifMatch: ifMatch)
            }
        )
    }

    private func handleSaveFailure(_ error: Error, draft sent: LeoConfigDraft) {
        switch error {
        case LeoConfigError.conflict(let current):
            conflict = Conflict(currentRevision: current)
        case LeoConfigError.invalid(let errors):
            draft = sent.applying(serverErrors: errors)
        default:
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: Add, rename, duplicate, delete

    /// `values` carries the fields an add requires beyond the name (a task's schedule).
    func add(name: String, values: [String: LeoConfigValue] = [:]) async {
        guard canRestructure, actions.contains(.add) else { return }
        await write(ifMatch: revisions.resolve(revision), preferring: name, selectingResult: true) { [resourceKey, client] ifMatch in
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
            ifMatch: revisions.resolve(revision), preferring: selection, keepingDraft: true, retryingConflict: true,
            onFailure: { _, error in failure = Self.message(for: error) },
            operation: { [resourceKey, client] ifMatch in
                try await client.update(resourceKey, name: name, patch: patch, ifMatch: ifMatch)
            }
        )
        return failure
    }

    func rename(to newName: String) async {
        guard canRestructure, actions.contains(.rename), let name = selection else { return }
        await write(ifMatch: revisions.resolve(revision), preferring: newName) { [resourceKey, client] ifMatch in
            try await client.rename(resourceKey, name: name, to: newName, ifMatch: ifMatch)
        }
    }

    func duplicate(as newName: String) async {
        guard canRestructure, actions.contains(.duplicate), let name = selection else { return }
        await write(ifMatch: revisions.resolve(revision), preferring: newName, selectingResult: true) { [resourceKey, client] ifMatch in
            try await client.duplicate(resourceKey, name: name, as: newName, ifMatch: ifMatch)
        }
    }

    func requestDelete() {
        guard canRestructure, actions.contains(.delete), let name = selection else { return }
        confirmation = .delete(name)
    }

    private func deleteSelected(_ name: String) async {
        await write(ifMatch: revisions.resolve(revision), preferring: nil) { [resourceKey, client] ifMatch in
            try await client.delete(resourceKey, name: name, ifMatch: ifMatch)
        }
    }

    // MARK: Confirmations and banners

    func confirm() async {
        guard let pending = confirmation else { return }
        confirmation = nil
        switch pending {
        case .delete(let name):
            await deleteSelected(name)
        case .discardChanges(let target):
            discardChanges()
            selectNow(target)
        }
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    func dismissRestartPrompt() {
        restartPrompt = nil
    }

    func dismissError() {
        errorMessage = nil
        warning = nil
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
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        warning = nil
        do {
            var sentWith = ifMatch
            let result: LeoConfigWriteResult
            do {
                result = try await operation(ifMatch)
            } catch LeoConfigError.conflict(let current) where retryingConflict {
                sentWith = current
                result = try await operation(current)
            }
            let draftWasCurrent = draft.map { revisions.resolve($0.revision) == sentWith } ?? true
            revisions.recordWrite(from: sentWith, to: result.revision)
            conflict = nil
            warning = result.warning
            if result.restartRequired.isNeeded { restartPrompt = result.restartRequired }
            let followed = selectingResult ? (result.item?.name ?? name) : name
            await refresh(preferring: followed, carrying: keepingDraft ? draft : nil, rebasing: draftWasCurrent)
        } catch {
            if let onFailure { onFailure(self, error) } else { errorMessage = Self.message(for: error) }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
