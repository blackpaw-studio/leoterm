import Foundation

/// One singleton resource's form as a value (defaults, web, client): the
/// document, its draft, and the banners a write leaves. Every transition is a
/// pure mutation, so the Mac's `ObservableObject` and the iOS reducers hold
/// the same state and move it the same way.
///
/// It follows the collection pane's rules. Every write carries the revision
/// the form was read at, mapped through the shared revision tracker (see
/// `LeoConfigSingletonOps`), and sends only the keys the user changed. A 409
/// keeps the draft and offers Reload (the user's edits over the new document)
/// or Overwrite (the same edits over the file as it is now, read again first);
/// a 422 lands on its fields; a restart-needed reply raises a prompt. Edits
/// made while a save is in flight stay in the form.
public struct LeoConfigSingletonState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    /// The daemon's file moved on since this form read it.
    public struct Conflict: Equatable, Sendable {
        public let currentRevision: String

        public init(currentRevision: String) {
            self.currentRevision = currentRevision
        }
    }

    public let resourceKey: String
    public let machineHost: String?
    /// The origin this device reached the machine at: the "edit on the web"
    /// link's way there when the machine publishes no URL of its own.
    public let webOrigin: URL?

    public private(set) var phase = Phase.loading
    public private(set) var draft: LeoConfigDraft?
    public private(set) var conflict: Conflict?
    public private(set) var restartPrompt: LeoConfigRestartRequired?
    /// The daemon saved but its reload failed.
    public private(set) var warning: String?
    /// A failure that belongs to no field.
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false

    /// As `LeoConfigSingletonOps.load` read it, with the resource transformed.
    public private(set) var schema: LeoConfigSchema?
    public private(set) var webDocument: LeoConfigDocument?
    public private(set) var references: [String: [String]]

    public init(resource: String, references: [String: [String]] = [:], machineHost: String? = nil, webOrigin: URL? = nil) {
        resourceKey = resource
        self.references = references
        self.machineHost = machineHost
        self.webOrigin = webOrigin
    }

    // MARK: Reading state

    private var resource: LeoConfigResource? { schema?.resource(resourceKey) }

    public var title: String { resource?.label ?? resourceKey.capitalized }
    public var isDirty: Bool { draft?.isDirty ?? false }
    public var canSave: Bool { draft?.canSave == true && conflict == nil && !isBusy }

    public var sections: [LeoConfigFormSection] {
        guard let draft, let resource, let schema else { return [] }
        return LeoConfigFormLayout.sections(
            resource: resource, harnesses: schema.harnesses, draft: draft, references: references, webLink: webLink
        )
    }

    public var webLink: URL? {
        LeoConfigWebLink.url(web: webDocument, machineHost: machineHost, resource: resourceKey, fallbackOrigin: webOrigin)
    }

    private var validator: LeoConfigValidator? {
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

    /// Takes what `LeoConfigSingletonOps.load` read. The schema stays even
    /// when the document failed to read. Names handed in while the load was
    /// out (a host added) win over what it read.
    public mutating func loaded(_ load: LeoConfigSingletonLoad) {
        if let schema = load.schema {
            self.schema = schema
            webDocument = load.webDocument
            references = load.references.merging(references) { _, current in current }
        }
        if let failure = load.failure {
            phase = .failed(Self.message(for: failure))
            return
        }
        guard let document = load.document else { return }
        apply(document, carrying: nil)
        phase = .loaded
    }

    /// The names behind a reference field changed (a host was added): the form
    /// offers them and judges the open edit against them.
    public mutating func setReferences(_ new: [String: [String]]) {
        references = new
        draft = draft?.validated(by: validator)
    }

    /// Clears the conflict before a Reload (or a reconnect's read) brings the
    /// new document in under the user's edits.
    public mutating func dismissConflict() {
        conflict = nil
    }

    /// `rebasing: false` leaves a carried draft with edits on the document it
    /// was opened on, so its next Save is judged against that revision.
    public mutating func apply(_ document: LeoConfigDocument, carrying carried: LeoConfigDraft?, rebasing: Bool = true) {
        let fresh = LeoConfigDraft(document: document, validator: validator)
        draft = carried.map { kept in
            rebasing || !kept.isDirty ? kept.rebased(onto: document) : kept
        } ?? fresh
    }

    /// A read after a write, a reload or a reconnect failed: the form stays as it was.
    public mutating func report(_ error: Error) {
        errorMessage = Self.message(for: error)
    }

    // MARK: Editing

    public mutating func set(_ path: String, _ value: LeoConfigValue) {
        draft?.set(path, value)
    }

    public mutating func revert(_ path: String) {
        draft?.revert(path)
    }

    /// Revert All, and the Settings window dropping the form's edits.
    public mutating func revertAll() {
        draft?.revert()
        errorMessage = nil
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

    /// Takes the outcome of `LeoConfigSingletonOps.write`: on success the
    /// banners it raised and the document it read back, which the open draft
    /// (with any edit made while the write was out) is carried onto. Only a
    /// draft based on the revision the write was sent with is rebased.
    /// Returns the write's failure, for `failed`.
    public mutating func finishWrite(_ outcome: LeoConfigSingletonWriteOutcome) -> Error? {
        isBusy = false
        switch outcome.result {
        case .failure(let error):
            return error
        case .success(let result):
            conflict = nil
            warning = result.warning
            if result.restartRequired.isNeeded { restartPrompt = result.restartRequired }
            switch outcome.document {
            case .success(let document)?: apply(document, carrying: draft, rebasing: outcome.draftWasCurrent)
            case .failure(let error)?: report(error)
            case nil: break
            }
            return nil
        }
    }

    /// Starts an Overwrite after a conflict, with the draft whose edits are replayed.
    public mutating func beginOverwrite() -> LeoConfigDraft? {
        guard conflict != nil, let stale = draft, beginWrite() else { return nil }
        return stale
    }

    /// Takes the outcome of `LeoConfigSingletonOps.overwrite`. The user's
    /// edits, including any made while it was out, stay on the draft over the
    /// fresh read, and a failed write lands on it like a Save does.
    public mutating func finishOverwrite(_ outcome: LeoConfigSingletonOverwriteOutcome) {
        switch outcome {
        case .readFailed(let error):
            isBusy = false
            if let draft { failed(error, sent: draft) } else { report(error) }
        case .nothingToSend(let replayed):
            isBusy = false
            draft = (draft ?? replayed).rebased(onto: replayed.document)
            conflict = nil
        case .sent(let replayed, let write):
            draft = (draft ?? replayed).rebased(onto: replayed.document)
            if let error = finishWrite(write) { failed(error, sent: replayed) }
        }
    }

    /// A Save that failed: a conflict raises the banner, a 422 lands on its
    /// fields, anything else is a message. The draft keeps the user's edits,
    /// including any made while the write was out.
    public mutating func failed(_ error: Error, sent: LeoConfigDraft) {
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

    public mutating func dismissRestartPrompt() {
        restartPrompt = nil
    }

    public mutating func dismissError() {
        errorMessage = nil
        warning = nil
    }
}
