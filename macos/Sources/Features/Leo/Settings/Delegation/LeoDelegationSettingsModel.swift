import Combine
import Foundation
import LeoKit

/// The Delegation pane: the role × profile matrix, the active profile, the
/// enabled switch, the hide list, and role and profile structure.
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
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase = Phase.loading
    @Published private(set) var document: LeoDelegationDocument? {
        didSet { matrix = LeoDelegationMatrix(document ?? LeoDelegationDocument(revision: "", configured: false)) }
    }
    @Published private(set) var matrix = LeoDelegationMatrix(LeoDelegationDocument(revision: "", configured: false))
    @Published private(set) var cellEditor: LeoDelegationCellEditor?
    @Published private(set) var useForEditor: LeoDelegationUseForEditor?
    @Published private(set) var hiddenAgentsEdit: LeoDelegationHiddenAgentsEdit?
    @Published private(set) var preview: LeoDelegationPreviewState?
    @Published private(set) var confirmation: LeoDelegationConfirmation?
    @Published private(set) var conflict: LeoDelegationConflict?
    @Published private(set) var restartPrompt: LeoConfigRestartRequired?
    /// The daemon saved but its reload failed.
    @Published private(set) var warning: String?
    /// A failure that belongs to no field.
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false
    @Published private var pendingEnabled: Bool?

    private var client: any LeoConfigClient
    private let revisions: LeoConfigRevisionTracker
    private let machineHost: String?
    private var namePattern: String?
    private var previewToken: UUID?
    private var webDocument: LeoConfigDocument?

    init(client: any LeoConfigClient, revisions: LeoConfigRevisionTracker, machineHost: String? = nil) {
        self.client = client
        self.revisions = revisions
        self.machineHost = machineHost
    }

    // MARK: Reading state

    var isConfigured: Bool { document?.configured == true }
    var warnings: [String] { document?.warnings ?? [] }
    var recentConsults: [LeoDelegationConsult] { document?.recentConsults ?? [] }
    var templates: [LeoDelegationTemplate] { document?.templates ?? [] }
    /// The switch as it reads now: the value being written until the daemon answers.
    var displayedEnabled: Bool { pendingEnabled ?? document?.enabled ?? false }
    var hiddenAgentNames: [String] { hiddenAgentsEdit?.names ?? document?.hideNativeAgents ?? [] }
    var hiddenAgentsAreDefault: Bool { hiddenAgentsEdit == nil && document?.hideNativeAgentsIsDefault == true }

    var webLink: URL? {
        LeoConfigWebLink.url(web: webDocument, machineHost: machineHost, resource: "delegation")
    }

    var canWrite: Bool { phase == .loaded && isConfigured && !isBusy }
    /// Structural changes wait for clean forms, so no edit is lost to a rename.
    var canRestructure: Bool { canWrite && !hasUnsavedChanges }

    func canDeleteRole(_ name: String) -> Bool {
        guard let row = matrix.rows.first(where: { $0.role.name == name }) else { return false }
        // The daemon refuses to leave `delegation.roles` empty.
        return !(row.role.declared && matrix.rows.filter(\.role.declared).count == 1)
    }

    func canDeleteProfile(_ name: String) -> Bool {
        matrix.profiles.contains { $0.name == name && !$0.active }
    }

    func roleNameError(_ name: String, excluding: String? = nil) -> String? {
        nameError(name, existing: matrix.rows.map(\.role.name), excluding: excluding)
    }

    func profileNameError(_ name: String, excluding: String? = nil) -> String? {
        nameError(name, existing: matrix.profiles.map(\.name), excluding: excluding)
    }

    private func nameError(_ name: String, existing: [String], excluding: String?) -> String? {
        let resource = LeoConfigResource(key: "delegation", kind: .collection, fields: [])
        return LeoConfigValidator(resource: resource, namePattern: namePattern).nameError(name, existing: existing, excluding: excluding)
    }

    // MARK: LeoSettingsPane

    var hasUnsavedChanges: Bool {
        cellEditor?.edit.isDirty == true || useForEditor?.isDirty == true || hiddenAgentsEdit?.isDirty == true
    }

    func discardChanges() {
        cellEditor = nil
        useForEditor = nil
        hiddenAgentsEdit = nil
        conflict = nil
    }

    /// The machine reconnected: read again through its new client and keep the
    /// user's edits over the fresh document.
    func reload(using client: any LeoConfigClient) async {
        self.client = client
        guard document != nil else { return await load() }
        conflict = nil
        do {
            adopt(try await client.delegation(), rebasing: allEditors)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: Loading

    func load() async {
        phase = .loading
        do {
            document = try await client.delegation()
            namePattern = (try? await client.schema())?.namePattern
            webDocument = try? await client.document("web")
            phase = .loaded
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    // MARK: Cell editing

    func beginCellEdit(profile: String, role: String) {
        guard isConfigured, let document, matrix.profiles.contains(where: { $0.name == profile }), matrix.rows.contains(where: { $0.role.name == role }) else { return }
        cellEditor = LeoDelegationCellEditor(
            profile: profile, role: role, edit: LeoDelegationCellEdit(base: matrix.cell(profile: profile, role: role)?.target), baseRevision: document.revision
        )
    }

    func setCellTemplate(_ template: String) { updateCell { $0.edit.target.template = template; $0.errors["template"] = nil } }
    func setCellModel(_ model: String) { updateCell { $0.edit.target.model = model; $0.errors["model"] = nil } }
    func setCellEffort(_ effort: String) { updateCell { $0.edit.target.effort = effort; $0.errors["effort"] = nil } }

    private func updateCell(_ change: (inout LeoDelegationCellEditor) -> Void) {
        guard var editor = cellEditor else { return }
        change(&editor)
        cellEditor = editor
    }

    /// Closes the popover of that cell. A late close of another cell's popover leaves the open editor alone.
    func cancelCellEdit(profile: String, role: String) {
        guard cellEditor?.profile == profile, cellEditor?.role == role else { return }
        cellEditor = nil
    }

    func saveCellEdit() async {
        guard let editor = cellEditor, editor.edit.isDirty else { return }
        await write(.cell)
    }

    // MARK: Description editing

    func beginUseForEdit(role: String) {
        guard isConfigured, let document, let spec = matrix.rows.first(where: { $0.role.name == role })?.role, spec.declared else { return }
        useForEditor = LeoDelegationUseForEditor(role: role, base: spec.useFor, text: spec.useFor, baseRevision: document.revision)
    }

    func setUseForText(_ text: String) {
        useForEditor?.text = text
        useForEditor?.error = nil
    }

    func cancelUseForEdit(role: String) {
        guard useForEditor?.role == role else { return }
        useForEditor = nil
    }

    func saveUseFor() async {
        guard useForEditor?.isDirty == true else { return }
        await write(.useFor)
    }

    // MARK: Hidden agents

    func setHiddenAgents(_ names: [String]) {
        guard isConfigured, let document else { return }
        var edit = hiddenAgentsEdit?.edit ?? LeoDelegationListEdit(base: document.hideNativeAgents)
        edit.names = names
        hiddenAgentsEdit = edit.isDirty ? LeoDelegationHiddenAgentsEdit(
            edit: edit, baseRevision: hiddenAgentsEdit?.baseRevision ?? document.revision
        ) : nil
    }

    func revertHiddenAgents() {
        hiddenAgentsEdit = nil
    }

    func saveHiddenAgents() async {
        guard hiddenAgentsEdit?.isDirty == true else { return }
        await write(.hiddenAgents)
    }

    // MARK: Enabled

    func setEnabled(_ enabled: Bool) async {
        guard canWrite else { return }
        pendingEnabled = enabled
        defer { pendingEnabled = nil }
        await write(.enabled(enabled), retryingConflict: true)
    }

    // MARK: Active profile

    /// Reads what activating `profile` would change and shows it; nothing is written.
    func requestActivate(_ profile: String) async {
        guard canWrite, canActivate(profile) else { return }
        let token = UUID()
        previewToken = token
        preview = .loading(profile)
        let outcome: LeoDelegationPreviewState
        do {
            outcome = .loaded(try await client.delegationPreview(profile: profile))
        } catch {
            outcome = .failed(profile: profile, message: Self.message(for: error))
        }
        guard previewToken == token else { return }
        preview = outcome
    }

    func canActivate(_ profile: String) -> Bool {
        matrix.profiles.contains { $0.name == profile && !$0.active }
    }

    func cancelPreview() {
        previewToken = nil
        preview = nil
    }

    func confirmActivate() async {
        guard case .loaded(let loaded)? = preview else { return }
        cancelPreview()
        await write(.activate(loaded.profile))
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

    func requestDeleteRole(_ name: String) {
        guard canRestructure, canDeleteRole(name) else { return }
        confirmation = .deleteRole(name: name, profiles: matrix.profilesRouting(role: name))
    }

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

    func requestDeleteProfile(_ name: String) {
        guard canRestructure, canDeleteProfile(name) else { return }
        confirmation = .deleteProfile(name: name, roleCount: matrix.routedRoleCount(in: name))
    }

    /// Takes the confirmation the alert showed: SwiftUI has already closed it,
    /// and cleared the state, by the time its button runs.
    func confirm(_ pending: LeoDelegationConfirmation) async {
        confirmation = nil
        guard canRestructure else { return }
        switch pending {
        case .deleteRole(let name, _): await write(.deleteRole(name))
        case .deleteProfile(let name, _): await write(.deleteProfile(name))
        }
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    // MARK: Conflicts and banners

    /// Reload after a conflict: the new document, with the user's edits over it.
    func reloadAfterConflict() async {
        guard conflict != nil else { return }
        conflict = nil
        do {
            adopt(try await client.delegation(), rebasing: allEditors)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Overwrite after a conflict: the same write, with the user's edits laid
    /// over a fresh read of the document and sent against its revision.
    func overwrite() async {
        guard let pending = conflict else { return }
        await write(pending.operation, overwriting: true)
    }

    func dismissRestartPrompt() {
        restartPrompt = nil
    }

    func dismissError() {
        errorMessage = nil
        warning = nil
    }

    // MARK: Writing

    private enum Editor { case cell, useFor, hiddenAgents }

    private var allEditors: Set<Editor> { [.cell, .useFor, .hiddenAgents] }

    private func write(_ operation: LeoDelegationOperation, retryingConflict: Bool = false, overwriting: Bool = false) async {
        guard canWrite, var base = document else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        warning = nil
        var ifMatch = revisions.resolve(revision(for: operation, in: base))
        if overwriting {
            do {
                base = try await client.delegation()
            } catch {
                errorMessage = Self.message(for: error)
                return
            }
            document = base
            ifMatch = base.revision
        }
        guard let send = request(operation, against: base) else { return }
        do {
            var sentWith = ifMatch
            let result: LeoDelegationWriteResult
            do {
                result = try await send(sentWith)
            } catch LeoConfigError.conflict(let current) where retryingConflict {
                sentWith = current
                result = try await send(current)
            }
            let current = editorsBased(on: sentWith)
            revisions.recordWrite(from: sentWith, to: result.revision)
            conflict = nil
            warning = result.warning
            if result.restartRequired.isNeeded { restartPrompt = result.restartRequired }
            await finish(operation, result: result, rebasing: current)
        } catch {
            fail(operation, error)
        }
    }

    /// The revision a write is sent against: an edit's own base, else the document's.
    private func revision(for operation: LeoDelegationOperation, in document: LeoDelegationDocument) -> String {
        switch operation {
        case .cell: cellEditor?.baseRevision ?? document.revision
        case .useFor: useForEditor?.baseRevision ?? document.revision
        case .hiddenAgents: hiddenAgentsEdit?.baseRevision ?? document.revision
        default: document.revision
        }
    }

    /// The open edits whose base is the revision a write was sent with (as the
    /// app's own writes have moved it on). Only these can follow that write
    /// onto the new document.
    private func editorsBased(on sent: String) -> Set<Editor> {
        var matching: Set<Editor> = []
        if let editor = cellEditor, revisions.resolve(editor.baseRevision) == sent { matching.insert(.cell) }
        if let editor = useForEditor, revisions.resolve(editor.baseRevision) == sent { matching.insert(.useFor) }
        if let edit = hiddenAgentsEdit, revisions.resolve(edit.baseRevision) == sent { matching.insert(.hiddenAgents) }
        return matching
    }

    /// The write the operation names, built from the edit as it is now over `document`.
    private func request(
        _ operation: LeoDelegationOperation, against document: LeoDelegationDocument
    ) -> (@Sendable (String) async throws -> LeoDelegationWriteResult)? {
        let client = client
        switch operation {
        case .cell:
            guard let editor = cellEditor else { return nil }
            let (profile, role) = (editor.profile, editor.role)
            let target = editor.edit.merged(onto: LeoDelegationMatrix(document).cell(profile: profile, role: role)?.target)
            return { try await client.setDelegationCell(profile: profile, role: role, target: target, ifMatch: $0) }
        case .useFor:
            guard let editor = useForEditor else { return nil }
            let (role, text) = (editor.role, editor.text)
            return { try await client.setRoleUseFor(role: role, useFor: text, ifMatch: $0) }
        case .hiddenAgents:
            guard let edit = hiddenAgentsEdit else { return nil }
            let names = edit.edit.applied(to: document.hideNativeAgents).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return { try await client.setHiddenAgents(names, ifMatch: $0) }
        case .enabled(let enabled): return { try await client.setDelegationEnabled(enabled, ifMatch: $0) }
        case .activate(let profile): return { try await client.setActiveProfile(profile, ifMatch: $0) }
        case .addRole(let name, let template): return { try await client.addDelegationRole(name: name, template: template, ifMatch: $0) }
        case .renameRole(let name, let newName): return { try await client.renameDelegationRole(name, to: newName, ifMatch: $0) }
        case .deleteRole(let name): return { try await client.deleteDelegationRole(name, ifMatch: $0) }
        case .addProfile(let name): return { try await client.addDelegationProfile(name: name, ifMatch: $0) }
        case .renameProfile(let name, let newName): return { try await client.renameDelegationProfile(name, to: newName, ifMatch: $0) }
        case .duplicateProfile(let name, let newName): return { try await client.duplicateDelegationProfile(name, as: newName, ifMatch: $0) }
        case .deleteProfile(let name): return { try await client.deleteDelegationProfile(name, ifMatch: $0) }
        }
    }

    /// A write went through: read the document it left (the reply carries it),
    /// close the edit that was saved, and carry the others over.
    private func finish(_ operation: LeoDelegationOperation, result: LeoDelegationWriteResult, rebasing editors: Set<Editor>) async {
        var fresh = result.item
        if fresh == nil {
            fresh = try? await client.delegation()
        }
        guard let fresh else {
            errorMessage = "Saved, but the new settings couldn’t be read back."
            return
        }
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
        adopt(fresh, rebasing: editors)
    }

    /// Makes `fresh` the document and moves the named open edits onto it.
    private func adopt(_ fresh: LeoDelegationDocument, rebasing editors: Set<Editor>) {
        document = fresh
        let newMatrix = LeoDelegationMatrix(fresh)
        if editors.contains(.cell), var editor = cellEditor {
            editor.edit = editor.edit.rebased(onto: newMatrix.cell(profile: editor.profile, role: editor.role)?.target)
            editor.baseRevision = fresh.revision
            editor.errors = [:]
            cellEditor = editor
        }
        if editors.contains(.useFor), var editor = useForEditor {
            if let current = newMatrix.rows.first(where: { $0.role.name == editor.role })?.role, current.declared {
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

    private func fail(_ operation: LeoDelegationOperation, _ error: Error) {
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

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
