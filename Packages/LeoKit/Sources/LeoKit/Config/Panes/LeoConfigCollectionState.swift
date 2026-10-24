import Foundation

/// One collection resource's pane as a value (templates, tasks, environments):
/// its list, the selected item's draft, and the banners a write leaves. Every
/// transition is a pure mutation, so the Mac's `ObservableObject` and the iOS
/// reducers hold the same state and move it the same way.
///
/// Every write carries the revision the pane read, mapped through the shared
/// `LeoConfigRevisionTracker` (see `LeoConfigCollectionOps`) so another pane's
/// write isn't a conflict. A 409 keeps the draft and offers Reload (rebase
/// onto the new document) or Overwrite (replay the edits over a fresh read); a
/// 422 lands on its fields; a restart-needed reply raises a prompt. Add,
/// rename, duplicate and delete are offered only for the actions the schema
/// lists, and only while the draft is clean.
public struct LeoConfigCollectionState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    /// A question waiting on the user.
    public enum Confirmation: Equatable, Sendable {
        case delete(String)
        /// Leave the item, dropping its unsaved edits, for `thenSelect`.
        case discardChanges(thenSelect: String?)
    }

    /// What a confirmed `Confirmation` asks the shell to do.
    public enum PendingAction: Equatable, Sendable {
        case delete(String)
        case discard(thenSelect: String?)
    }

    /// The daemon's file moved on since this pane read it.
    public struct Conflict: Equatable, Sendable {
        public let currentRevision: String

        public init(currentRevision: String) {
            self.currentRevision = currentRevision
        }
    }

    public let resourceKey: String
    public let machineHost: String?
    /// The Mac shows the first item at once. A phone pushes a screen on
    /// selection, so it starts with none.
    public let autoSelectsFirst: Bool

    public private(set) var phase = Phase.loading
    public private(set) var items: [LeoConfigItem] = []
    public private(set) var selection: String?
    public private(set) var draft: LeoConfigDraft?
    public private(set) var conflict: Conflict?
    public private(set) var restartPrompt: LeoConfigRestartRequired?
    /// The daemon saved but its reload failed.
    public private(set) var warning: String?
    /// A failure that belongs to no field.
    public private(set) var errorMessage: String?
    public private(set) var confirmation: Confirmation?
    public private(set) var isBusy = false

    public private(set) var schema: LeoConfigSchema?
    public private(set) var webDocument: LeoConfigDocument?
    public private(set) var references: [String: [String]]
    /// The file revision the list was read at.
    public private(set) var revision = ""

    public init(
        resource: String, references: [String: [String]] = [:], machineHost: String? = nil, autoSelectsFirst: Bool = true
    ) {
        resourceKey = resource
        self.references = references
        self.machineHost = machineHost
        self.autoSelectsFirst = autoSelectsFirst
    }

    // MARK: Reading state

    private var resource: LeoConfigResource? { schema?.resource(resourceKey) }

    public var title: String { resource?.label ?? resourceKey.capitalized }
    public var actions: Set<LeoConfigAction> { Set(resource?.actions ?? []) }

    public var isDirty: Bool { draft?.isDirty ?? false }
    public var canSave: Bool { draft?.canSave == true && conflict == nil && !isBusy }
    /// Structural changes wait for a clean draft, so no edit is lost to a rename.
    public var canRestructure: Bool { !hasUnsavedChanges(extra: false) && !isBusy && phase == .loaded }

    /// A pane that edits more than the form (the task prompt) passes its own
    /// unsaved state as `extra`, so leaving the item asks about it too.
    public func hasUnsavedChanges(extra: Bool) -> Bool { isDirty || extra }

    /// `action` is offered by the schema and the pane is in a state to do it.
    public func allows(_ action: LeoConfigAction) -> Bool {
        canRestructure && actions.contains(action)
    }

    public var sections: [LeoConfigFormSection] {
        guard let draft, let resource, let schema else { return [] }
        return LeoConfigFormLayout.sections(
            resource: resource, harnesses: schema.harnesses, draft: draft, references: references, webLink: webLink
        )
    }

    public var webLink: URL? {
        LeoConfigWebLink.url(web: webDocument, machineHost: machineHost, resource: resourceKey, item: selection)
    }

    public func nameError(_ name: String, excluding: String? = nil) -> String? {
        validator?.nameError(name, existing: items.map(\.name), excluding: excluding)
    }

    public var validator: LeoConfigValidator? {
        guard let resource, let schema else { return nil }
        return LeoConfigValidator(resource: resource, harnesses: schema.harnesses, namePattern: schema.namePattern, references: references)
    }

    /// What an error says to the user.
    public static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Loading

    public mutating func beginLoading() {
        phase = .loading
    }

    /// Takes what `LeoConfigCollectionOps.load` read. The schema and the names
    /// behind it stay even when the collection itself failed to read.
    public mutating func loaded(_ load: LeoConfigCollectionLoad) {
        if let schema = load.schema {
            self.schema = schema
            webDocument = load.webDocument
            references = load.references
        }
        if let failure = load.failure {
            phase = .failed(Self.message(for: failure))
            return
        }
        guard let collection = load.collection else { return }
        apply(collection, preferring: selection, carrying: nil)
        phase = .loaded
    }

    /// The machine reconnected: its Reload is about to read again and keep the user's edits.
    public mutating func dismissConflict() {
        conflict = nil
    }

    /// `rebasing: false` leaves a carried draft with edits on the document it
    /// was opened on, so its next Save is judged against that revision.
    public mutating func apply(
        _ collection: LeoConfigCollection, preferring name: String?, carrying carried: LeoConfigDraft?, rebasing: Bool = true
    ) {
        items = collection.items
        revision = collection.revision
        let fallback = autoSelectsFirst ? items.first?.name : nil
        let chosen = [name, selection].lazy.compactMap { $0 }.first { wanted in items.contains { $0.name == wanted } } ?? fallback
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

    /// A read after a write or a reload failed: the list stays as it was.
    public mutating func report(_ error: Error) {
        errorMessage = Self.message(for: error)
    }

    private func document(of item: LeoConfigItem) -> LeoConfigDocument {
        LeoConfigDocument(
            revision: revision, name: item.name, values: item.values, inherited: item.inherited, effectiveHarness: item.effectiveHarness
        )
    }

    // MARK: Editing

    public mutating func set(_ path: String, _ value: LeoConfigValue) {
        draft?.set(path, value)
    }

    public mutating func revert(_ path: String) {
        draft?.revert(path)
    }

    public mutating func revertAll() {
        draft?.revert()
        errorMessage = nil
    }

    /// Drops the form's edits (leaving the item).
    public mutating func discardEdits() {
        draft?.revert()
    }

    /// Selects `name`, or asks first when edits (the form's, or `extraUnsaved`) would be lost.
    public mutating func requestSelect(_ name: String?, extraUnsaved: Bool) {
        guard name != selection else { return }
        guard !hasUnsavedChanges(extra: extraUnsaved) else {
            confirmation = .discardChanges(thenSelect: name)
            return
        }
        selectNow(name)
    }

    public mutating func selectNow(_ name: String?) {
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

    // MARK: Writing

    /// Starts a write, or refuses while one is running.
    public mutating func beginWrite() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        warning = nil
        return true
    }

    /// Takes the outcome of `LeoConfigCollectionOps.write`: on success the
    /// banners it raised and the list it read back (`preferring` is the item
    /// to select, `selectingResult` follows the item the daemon returned,
    /// `keepingDraft` rebases the open draft onto what was read, but only a
    /// draft whose base is the revision the write was sent with: one left
    /// behind by an earlier retry keeps its own, however many writes follow).
    /// Returns the write's failure, which the shell routes to `failed` or to a banner.
    public mutating func finishWrite(
        _ outcome: LeoConfigWriteOutcome, preferring name: String?, selectingResult: Bool = false, keepingDraft: Bool = false
    ) -> Error? {
        isBusy = false
        errorMessage = nil
        warning = nil
        switch outcome.result {
        case .failure(let error):
            return error
        case .success(let result):
            conflict = nil
            warning = result.warning
            if result.restartRequired.isNeeded { restartPrompt = result.restartRequired }
            let followed = selectingResult ? (result.item?.name ?? name) : name
            switch outcome.collection {
            case .success(let collection)?:
                apply(collection, preferring: followed, carrying: keepingDraft ? draft : nil, rebasing: outcome.draftWasCurrent)
            case .failure(let error)?:
                report(error)
            case nil:
                break
            }
            return nil
        }
    }

    /// Starts an Overwrite after a conflict: the draft whose edits are
    /// replayed, and the item they belong to.
    public mutating func beginOverwrite() -> (stale: LeoConfigDraft, name: String)? {
        guard conflict != nil, let stale = draft, let name = selection, !isBusy else { return nil }
        isBusy = true
        return (stale, name)
    }

    /// Takes the outcome of `LeoConfigCollectionOps.overwrite`. The user's
    /// edits stay on the draft (replayed over the fresh read), and a failed
    /// write lands on it like a Save does.
    public mutating func finishOverwrite(_ outcome: LeoConfigOverwriteOutcome, name: String) {
        switch outcome {
        case .readFailed(let error):
            isBusy = false
            report(error)
        case .nothingToSend(let replayed, let collection):
            isBusy = false
            draft = replayed
            conflict = nil
            switch collection {
            case .success(let collection): apply(collection, preferring: name, carrying: replayed)
            case .failure(let error): report(error)
            }
        case .sent(let replayed, let write):
            draft = replayed
            if let error = finishWrite(write, preferring: name) { failed(error, sent: replayed) }
        }
    }

    /// A Save that failed: a conflict raises the banner, a 422 lands on its
    /// fields, anything else is a message. The draft keeps the user's edits.
    public mutating func failed(_ error: Error, sent: LeoConfigDraft) {
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

    /// Asks before deleting `name` (the row the user acted on).
    public mutating func requestDelete(_ name: String?) {
        guard allows(.delete), let name else { return }
        confirmation = .delete(name)
    }

    // MARK: Confirmations and banners

    /// Takes the confirmation a button showed, which the alert has already
    /// closed by the time its action runs, and says what to do.
    public mutating func take(_ pending: Confirmation) -> PendingAction {
        confirmation = nil
        switch pending {
        case .delete(let name): return .delete(name)
        case .discardChanges(let target): return .discard(thenSelect: target)
        }
    }

    public mutating func cancelConfirmation() {
        confirmation = nil
    }

    public mutating func dismissRestartPrompt() {
        restartPrompt = nil
    }

    public mutating func dismissError() {
        errorMessage = nil
        warning = nil
    }
}
