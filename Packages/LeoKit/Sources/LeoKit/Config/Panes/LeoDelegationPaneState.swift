import Foundation

/// The Delegation pane as a value: the role × profile document, the open
/// edits (a cell, a role's description, the hide list), the Make Active
/// preview, and the banners a write leaves. Every transition is a pure
/// mutation, so the Mac's `ObservableObject` and the iOS reducer hold the same
/// state and move it the same way; `LeoDelegationOps` does the I/O.
///
/// Every write carries `If-Match`. A write of what the user typed is sent
/// against the revision that edit was based on, with only the edited keys
/// laid over what is current, and a 409 keeps the edit and offers Reload (the
/// edit rebased onto the new document) or Overwrite (the same edit over a
/// fresh read). A single-key write beside an open edit (the enabled switch)
/// rebases that edit only when the edit's base is the revision the write was
/// sent with. Structure waits for clean forms.
public struct LeoDelegationPaneState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    public let machineHost: String?
    /// The origin this device reached the machine at, for the web link.
    public let webOrigin: URL?

    public private(set) var phase = Phase.loading
    public private(set) var document: LeoDelegationDocument? {
        didSet { matrix = LeoDelegationMatrix(document ?? Self.unconfigured) }
    }
    public private(set) var matrix = LeoDelegationMatrix(Self.unconfigured)
    public private(set) var cellEditor: LeoDelegationCellEditor?
    public private(set) var useForEditor: LeoDelegationUseForEditor?
    public private(set) var hiddenAgentsEdit: LeoDelegationHiddenAgentsEdit?
    public private(set) var preview: LeoDelegationPreviewState?
    public private(set) var confirmation: LeoDelegationConfirmation?
    public private(set) var conflict: LeoDelegationConflict?
    public private(set) var restartPrompt: LeoConfigRestartRequired?
    /// The daemon saved but its reload failed.
    public private(set) var warning: String?
    /// A failure that belongs to no field.
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false
    /// The enabled switch's value while its write is out.
    public private(set) var pendingEnabled: Bool?
    public private(set) var namePattern: String?
    public private(set) var webDocument: LeoConfigDocument?

    private static let unconfigured = LeoDelegationDocument(revision: "", configured: false)

    public init(machineHost: String? = nil, webOrigin: URL? = nil) {
        self.machineHost = machineHost
        self.webOrigin = webOrigin
    }

    // MARK: Reading state

    public var isConfigured: Bool { document?.configured == true }
    public var warnings: [String] { document?.warnings ?? [] }
    public var recentConsults: [LeoDelegationConsult] { document?.recentConsults ?? [] }
    public var templates: [LeoDelegationTemplate] { document?.templates ?? [] }
    /// The switch as it reads now: the value being written until the daemon answers.
    public var displayedEnabled: Bool { pendingEnabled ?? document?.enabled ?? false }
    public var hiddenAgentNames: [String] { hiddenAgentsEdit?.names ?? document?.hideNativeAgents ?? [] }
    public var hiddenAgentsAreDefault: Bool { hiddenAgentsEdit == nil && document?.hideNativeAgentsIsDefault == true }

    public var webLink: URL? {
        LeoConfigWebLink.url(web: webDocument, machineHost: machineHost, resource: "delegation", fallbackOrigin: webOrigin)
    }

    public var canWrite: Bool { phase == .loaded && isConfigured && !isBusy }
    /// Structural changes wait for clean forms, so no edit is lost to a rename.
    public var canRestructure: Bool { canWrite && !hasUnsavedChanges }

    public var hasUnsavedChanges: Bool {
        cellEditor?.edit.isDirty == true || useForEditor?.isDirty == true || hiddenAgentsEdit?.isDirty == true
    }

    public var edits: LeoDelegationEdits {
        LeoDelegationEdits(cell: cellEditor, useFor: useForEditor, hiddenAgents: hiddenAgentsEdit)
    }

    public func canDeleteRole(_ name: String) -> Bool {
        guard let row = matrix.rows.first(where: { $0.role.name == name }) else { return false }
        // The daemon refuses to leave `delegation.roles` empty.
        return !(row.role.declared && matrix.rows.filter(\.role.declared).count == 1)
    }

    public func canDeleteProfile(_ name: String) -> Bool {
        matrix.profiles.contains { $0.name == name && !$0.active }
    }

    public func canActivate(_ profile: String) -> Bool {
        matrix.profiles.contains { $0.name == profile && !$0.active }
    }

    public func roleNameError(_ name: String, excluding: String? = nil) -> String? {
        nameError(name, existing: matrix.rows.map(\.role.name), excluding: excluding)
    }

    public func profileNameError(_ name: String, excluding: String? = nil) -> String? {
        nameError(name, existing: matrix.profiles.map(\.name), excluding: excluding)
    }

    private func nameError(_ name: String, existing: [String], excluding: String?) -> String? {
        let resource = LeoConfigResource(key: "delegation", kind: .collection, fields: [])
        return LeoConfigValidator(resource: resource, namePattern: namePattern).nameError(name, existing: existing, excluding: excluding)
    }

    /// What an error says to the user.
    public static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Loading

    public mutating func beginLoading() {
        phase = .loading
    }

    public mutating func loaded(_ load: LeoDelegationLoad) {
        guard let loaded = load.document else {
            phase = .failed(Self.message(for: load.failure ?? LeoConfigError.unsupported))
            return
        }
        document = loaded
        namePattern = load.namePattern
        webDocument = load.webDocument
        phase = .loaded
    }

    /// A Reload after a conflict is starting: the banner goes, and the read
    /// that follows rebases every open edit.
    public mutating func beginReload() -> Bool {
        guard conflict != nil else { return false }
        conflict = nil
        return true
    }

    /// The machine reconnected: its read is about to rebase every open edit.
    public mutating func dismissConflict() {
        conflict = nil
    }

    /// A read after a reload or a write failed: the pane stays as it was.
    public mutating func report(_ error: Error) {
        errorMessage = Self.message(for: error)
    }

    /// Drops every open edit (leaving the pane).
    public mutating func discardChanges() {
        cellEditor = nil
        useForEditor = nil
        hiddenAgentsEdit = nil
        conflict = nil
    }

    // MARK: Cell editing

    public mutating func beginCellEdit(profile: String, role: String) {
        guard isConfigured, let document, matrix.profiles.contains(where: { $0.name == profile }),
              matrix.rows.contains(where: { $0.role.name == role }) else { return }
        cellEditor = LeoDelegationCellEditor(
            profile: profile, role: role, edit: LeoDelegationCellEdit(base: matrix.cell(profile: profile, role: role)?.target),
            baseRevision: document.revision
        )
    }

    public mutating func setCellTemplate(_ template: String) {
        cellEditor?.edit.target.template = template
        cellEditor?.errors["template"] = nil
    }

    public mutating func setCellModel(_ model: String) {
        cellEditor?.edit.target.model = model
        cellEditor?.errors["model"] = nil
    }

    public mutating func setCellEffort(_ effort: String) {
        cellEditor?.edit.target.effort = effort
        cellEditor?.errors["effort"] = nil
    }

    /// Closes that cell's editor. A late close of another cell's editor leaves the open one alone.
    public mutating func cancelCellEdit(profile: String, role: String) {
        guard cellEditor?.profile == profile, cellEditor?.role == role else { return }
        cellEditor = nil
    }

    // MARK: Description editing

    public mutating func beginUseForEdit(role: String) {
        guard isConfigured, let document, let spec = matrix.rows.first(where: { $0.role.name == role })?.role, spec.declared else { return }
        useForEditor = LeoDelegationUseForEditor(role: role, base: spec.useFor, text: spec.useFor, baseRevision: document.revision)
    }

    public mutating func setUseForText(_ text: String) {
        useForEditor?.text = text
        useForEditor?.error = nil
    }

    public mutating func cancelUseForEdit(role: String) {
        guard useForEditor?.role == role else { return }
        useForEditor = nil
    }

    // MARK: Hidden agents

    public mutating func setHiddenAgents(_ names: [String]) {
        guard isConfigured, let document else { return }
        var edit = hiddenAgentsEdit?.edit ?? LeoDelegationListEdit(base: document.hideNativeAgents)
        edit.names = names
        hiddenAgentsEdit = edit.isDirty ? LeoDelegationHiddenAgentsEdit(
            edit: edit, baseRevision: hiddenAgentsEdit?.baseRevision ?? document.revision
        ) : nil
    }

    public mutating func revertHiddenAgents() {
        hiddenAgentsEdit = nil
    }

    // MARK: Active profile

    /// Opens the Make Active dialog on its loading state, or refuses.
    public mutating func beginPreview(_ profile: String) -> Bool {
        guard canWrite, canActivate(profile) else { return false }
        preview = .loading(profile)
        return true
    }

    /// The answer to the preview asked for `profile`, taken only while the
    /// dialog still waits on that profile (a late answer after a cancel, or
    /// for a profile since replaced, is dropped).
    public mutating func finishPreview(_ outcome: LeoDelegationPreviewState, for profile: String) {
        guard case .loading(let waiting)? = preview, waiting == profile else { return }
        preview = outcome
    }

    public mutating func cancelPreview() {
        preview = nil
    }

    /// Closes the dialog and names the write its confirm asks for.
    public mutating func confirmActivate() -> LeoDelegationOperation? {
        guard case .loaded(let loaded)? = preview else { return nil }
        preview = nil
        return .activate(loaded.profile)
    }

    // MARK: Confirmations

    public mutating func requestDeleteRole(_ name: String) {
        guard canRestructure, canDeleteRole(name) else { return }
        confirmation = .deleteRole(name: name, profiles: matrix.profilesRouting(role: name))
    }

    public mutating func requestDeleteProfile(_ name: String) {
        guard canRestructure, canDeleteProfile(name) else { return }
        confirmation = .deleteProfile(name: name, roleCount: matrix.routedRoleCount(in: name))
    }

    /// Takes the confirmation the alert showed (its own payload: the alert has
    /// closed by the time its button runs) and names the write, if structure
    /// can still change.
    public mutating func take(_ pending: LeoDelegationConfirmation) -> LeoDelegationOperation? {
        confirmation = nil
        guard canRestructure else { return nil }
        switch pending {
        case .deleteRole(let name, _): return .deleteRole(name)
        case .deleteProfile(let name, _): return .deleteProfile(name)
        }
    }

    public mutating func cancelConfirmation() {
        confirmation = nil
    }

    // MARK: Writing

    /// Starts a write, or refuses while one is running (or the pane can't write).
    public mutating func beginWrite(_ operation: LeoDelegationOperation) -> Bool {
        guard canWrite, document != nil else { return false }
        isBusy = true
        errorMessage = nil
        warning = nil
        if case .enabled(let enabled) = operation { pendingEnabled = enabled }
        return true
    }

    /// Takes the outcome of `LeoDelegationOps.write`. A landed write closes the
    /// edit it saved (every edit, for a change of structure) and carries the
    /// named others onto the document it left.
    public mutating func finishWrite(_ outcome: LeoDelegationWriteOutcome) {
        isBusy = false
        pendingEnabled = nil
        if let fresh = outcome.fresh { document = fresh }
        switch outcome.reply {
        case .readFailed(let error):
            report(error)
        case .nothingToSend:
            break
        case .failed(let error):
            fail(outcome.operation, error)
        case .sent(let result, let rebasing, let readBack):
            conflict = nil
            warning = result.warning
            if result.restartRequired.isNeeded { restartPrompt = result.restartRequired }
            guard let readBack else {
                errorMessage = "Saved, but the new settings couldn’t be read back."
                return
            }
            close(after: outcome.operation)
            adopt(readBack, rebasing: rebasing)
        }
    }

    private mutating func close(after operation: LeoDelegationOperation) {
        switch operation {
        case .cell: cellEditor = nil
        case .useFor: useForEditor = nil
        case .hiddenAgents: hiddenAgentsEdit = nil
        default: break
        }
        if operation.changesStructure {
            cellEditor = nil
            useForEditor = nil
            hiddenAgentsEdit = nil
        }
    }

    /// Makes `fresh` the document and moves the named open edits onto it.
    public mutating func adopt(_ fresh: LeoDelegationDocument, rebasing editors: Set<LeoDelegationEditor>) {
        document = fresh
        if editors.contains(.cell), var editor = cellEditor {
            editor.edit = editor.edit.rebased(onto: matrix.cell(profile: editor.profile, role: editor.role)?.target)
            editor.baseRevision = fresh.revision
            editor.errors = [:]
            cellEditor = editor
        }
        if editors.contains(.useFor), var editor = useForEditor {
            if let current = matrix.rows.first(where: { $0.role.name == editor.role })?.role, current.declared {
                editor.text = editor.isDirty ? editor.text : current.useFor
                editor.base = current.useFor
                editor.baseRevision = fresh.revision
                editor.error = nil
                useForEditor = editor
            } else {
                useForEditor = nil
            }
        }
        if editors.contains(.hiddenAgents), var edit = hiddenAgentsEdit {
            edit.edit = edit.edit.rebased(onto: fresh.hideNativeAgents)
            edit.baseRevision = fresh.revision
            hiddenAgentsEdit = edit.isDirty ? edit : nil
        }
    }

    /// A write that failed: a conflict keeps the operation for Overwrite, a
    /// 422 lands on the edit's fields, anything else is a message.
    public mutating func fail(_ operation: LeoDelegationOperation, _ error: Error) {
        switch error {
        case LeoConfigError.conflict(let current):
            conflict = LeoDelegationConflict(operation: operation, currentRevision: current)
        case LeoConfigError.invalid(let errors):
            let first = errors.first?.message ?? Self.message(for: error)
            switch operation {
            case .cell:
                cellEditor?.errors = Dictionary(errors.map { ($0.field, $0.inlineMessage) }, uniquingKeysWith: { first, _ in first })
            case .useFor:
                useForEditor?.error = first
            default:
                errorMessage = first
            }
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
