import Combine
import Foundation
import LeoKit

/// One singleton resource's form (defaults, web, client): the document, its
/// draft, and Save / Revert against the machine's config API.
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
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// The daemon's file moved on since this form read it.
    struct Conflict: Equatable {
        let currentRevision: String
    }

    let resourceKey: String

    @Published private(set) var phase = Phase.loading
    @Published private(set) var draft: LeoConfigDraft?
    @Published private(set) var conflict: Conflict?
    @Published private(set) var restartPrompt: LeoConfigRestartRequired?
    /// The daemon saved but its reload failed.
    @Published private(set) var warning: String?
    /// A failure that belongs to no field.
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false

    private var client: any LeoConfigClient
    private let revisions: LeoConfigRevisionTracker
    private var references: [String: [String]]
    private let machineHost: String?
    /// Adjusts the daemon's description of the resource (a string field the
    /// app draws as a pick from another collection).
    private let resourceTransform: (LeoConfigResource) -> LeoConfigResource
    private var schema: LeoConfigSchema?
    private var webDocument: LeoConfigDocument?

    init(
        resource: String, client: any LeoConfigClient, revisions: LeoConfigRevisionTracker, references: [String: [String]] = [:],
        machineHost: String? = nil, resourceTransform: @escaping (LeoConfigResource) -> LeoConfigResource = { $0 }
    ) {
        resourceKey = resource
        self.client = client
        self.revisions = revisions
        self.references = references
        self.machineHost = machineHost
        self.resourceTransform = resourceTransform
    }

    // MARK: Reading state

    private var resource: LeoConfigResource? { schema?.resource(resourceKey).map(resourceTransform) }

    var title: String { resource?.label ?? resourceKey.capitalized }
    var isDirty: Bool { draft?.isDirty ?? false }
    var canSave: Bool { draft?.canSave == true && conflict == nil && !isBusy }

    var sections: [LeoConfigFormSection] {
        guard let draft, let resource, let schema else { return [] }
        return LeoConfigFormLayout.sections(
            resource: resource, harnesses: schema.harnesses, draft: draft, references: references, webLink: webLink
        )
    }

    var webLink: URL? {
        LeoConfigWebLink.url(web: webDocument, machineHost: machineHost, resource: resourceKey)
    }

    private var validator: LeoConfigValidator? {
        guard let resource, let schema else { return nil }
        return LeoConfigValidator(resource: resource, harnesses: schema.harnesses, namePattern: schema.namePattern, references: references)
    }

    /// The names behind a reference field changed (a host was added): the form
    /// offers them and judges the open edit against them.
    func setReferences(_ new: [String: [String]]) {
        references = new
        draft = draft?.validated(by: validator)
    }

    // MARK: LeoSettingsPane

    var hasUnsavedChanges: Bool { isDirty }

    func discardChanges() {
        draft?.revert()
        errorMessage = nil
    }

    /// The machine reconnected: read again through its new client and keep the
    /// user's edits over the fresh document.
    func reload(using client: any LeoConfigClient) async {
        self.client = client
        guard schema != nil else { return await load() }
        conflict = nil
        await refresh(carrying: draft)
    }

    // MARK: Loading

    func load() async {
        phase = .loading
        do {
            schema = try await client.schema()
            webDocument = try? await client.document("web")
            apply(try await client.document(resourceKey), carrying: nil)
            phase = .loaded
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func refresh(carrying carried: LeoConfigDraft?, rebasing: Bool = true) async {
        do {
            apply(try await client.document(resourceKey), carrying: carried, rebasing: rebasing)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// `rebasing: false` leaves a carried draft with edits on the document it
    /// was opened on, so its next Save is judged against that revision.
    private func apply(_ document: LeoConfigDocument, carrying carried: LeoConfigDraft?, rebasing: Bool = true) {
        let fresh = LeoConfigDraft(document: document, validator: validator)
        draft = carried.map { kept in
            rebasing || !kept.isDirty ? kept.rebased(onto: document) : kept
        } ?? fresh
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

    // MARK: Saving

    func save() async {
        guard canSave, let sent = draft else { return }
        let ifMatch = revisions.resolve(sent.revision)
        await write(sent: sent) { [resourceKey, client] in
            (ifMatch, try await client.update(resourceKey, name: nil, patch: sent.patch, ifMatch: ifMatch))
        }
    }

    /// Reload after a conflict: the new document, with the user's edits over it.
    func reloadAfterConflict() async {
        guard conflict != nil else { return }
        conflict = nil
        await refresh(carrying: draft)
    }

    /// Overwrite after a conflict: the user's edits replayed over the file as
    /// it is now, then sent against that revision. A list the edit added to
    /// keeps what the other writer put in it.
    func overwrite() async {
        guard conflict != nil, let stale = draft else { return }
        await write(sent: stale) { [resourceKey, client, weak self] in
            let current = try await client.document(resourceKey)
            let replayed = stale.rebased(onto: current)
            self?.draft = replayed
            guard replayed.isDirty else { return nil }
            return (current.revision, try await client.update(resourceKey, name: nil, patch: replayed.patch, ifMatch: current.revision))
        }
    }

    private func handleSaveFailure(_ error: Error, sent: LeoConfigDraft) {
        switch error {
        case LeoConfigError.conflict(let current):
            conflict = Conflict(currentRevision: current)
        case LeoConfigError.invalid(let errors):
            draft = (draft ?? sent).applying(serverErrors: errors)
        default:
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: Banners

    func dismissRestartPrompt() {
        restartPrompt = nil
    }

    func dismissError() {
        errorMessage = nil
        warning = nil
    }

    // MARK: Writing

    /// Runs one write, then reads the document again and rebases the open
    /// draft onto it, so an edit made while the write was in flight stays and
    /// the edits that were sent drop out. The draft is rebased only when its
    /// base is the revision the write was sent with. `operation` answers nil
    /// when there turned out to be nothing to send.
    private func write(sent: LeoConfigDraft, operation: () async throws -> (sentWith: String, result: LeoConfigWriteResult)?) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        warning = nil
        do {
            guard let (sentWith, result) = try await operation() else {
                conflict = nil
                return
            }
            let draftWasCurrent = draft.map { revisions.resolve($0.revision) == sentWith } ?? true
            revisions.recordWrite(from: sentWith, to: result.revision)
            conflict = nil
            warning = result.warning
            if result.restartRequired.isNeeded { restartPrompt = result.restartRequired }
            await refresh(carrying: draft, rebasing: draftWasCurrent)
        } catch {
            handleSaveFailure(error, sent: draft ?? sent)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
