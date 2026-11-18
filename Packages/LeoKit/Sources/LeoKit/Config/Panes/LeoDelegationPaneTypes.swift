import Foundation

/// An open cell editor: the cell being edited, the revision its base was
/// read at, and the daemon's complaints about the keys it last refused.
public struct LeoDelegationCellEditor: Equatable, Sendable {
    public let profile: String
    public let role: String
    public var edit: LeoDelegationCellEdit
    public var baseRevision: String
    /// By field (`template`, `model`, `effort`); `""` belongs to no field.
    public var errors: [String: String] = [:]

    public init(profile: String, role: String, edit: LeoDelegationCellEdit, baseRevision: String, errors: [String: String] = [:]) {
        self.profile = profile
        self.role = role
        self.edit = edit
        self.baseRevision = baseRevision
        self.errors = errors
    }
}

/// An open edit of a declared role's description.
public struct LeoDelegationUseForEditor: Equatable, Sendable {
    public let role: String
    public var base: String
    public var text: String
    public var baseRevision: String
    public var error: String?

    public init(role: String, base: String, text: String, baseRevision: String, error: String? = nil) {
        self.role = role
        self.base = base
        self.text = text
        self.baseRevision = baseRevision
        self.error = error
    }

    public var isDirty: Bool { text != base }
}

/// The hide list being edited: the list as it was read and the one typed,
/// kept as the names added and removed so it replays over a newer list.
public struct LeoDelegationHiddenAgentsEdit: Equatable, Sendable {
    public var edit: LeoDelegationListEdit
    public var baseRevision: String

    public init(edit: LeoDelegationListEdit, baseRevision: String) {
        self.edit = edit
        self.baseRevision = baseRevision
    }

    public var names: [String] { edit.names }
    public var isDirty: Bool { edit.isDirty }
}

/// The Make Active dialog: the daemon's account of what switching would change.
public enum LeoDelegationPreviewState: Equatable, Sendable {
    case loading(String)
    case loaded(LeoDelegationPreview)
    case failed(profile: String, message: String)

    public var profile: String {
        switch self {
        case .loading(let profile), .failed(let profile, _): profile
        case .loaded(let preview): preview.profile
        }
    }
}

/// A question waiting on the user. Each names what the delete takes with it.
public enum LeoDelegationConfirmation: Equatable, Sendable {
    /// The role is removed from every profile that routes it.
    case deleteRole(name: String, profiles: [String])
    case deleteProfile(name: String, roleCount: Int)
}

/// A write the pane can send, kept so a conflict can be resolved by sending it again.
public enum LeoDelegationOperation: Equatable, Sendable {
    case cell
    case useFor
    case hiddenAgents
    case enabled(Bool)
    case activate(String)
    case addRole(name: String, template: String)
    case renameRole(String, to: String)
    case deleteRole(String)
    case addProfile(String)
    case renameProfile(String, to: String)
    case duplicateProfile(String, as: String)
    case deleteProfile(String)

    /// An edit of what the user typed in a form field: it is sent against the
    /// revision that edit was based on, and only its own keys are laid over
    /// whatever is current.
    public var isFormEdit: Bool {
        switch self {
        case .cell, .useFor, .hiddenAgents: true
        default: false
        }
    }

    /// A change of shape: it needs every form clean, and closes the clean ones.
    public var changesStructure: Bool {
        switch self {
        case .addRole, .renameRole, .deleteRole, .addProfile, .renameProfile, .duplicateProfile, .deleteProfile: true
        default: false
        }
    }
}

/// The daemon's file moved on since the pane read it.
public struct LeoDelegationConflict: Equatable, Sendable {
    public let operation: LeoDelegationOperation
    public let currentRevision: String

    public init(operation: LeoDelegationOperation, currentRevision: String) {
        self.operation = operation
        self.currentRevision = currentRevision
    }
}

/// One of the pane's open edits.
public enum LeoDelegationEditor: Hashable, Sendable, CaseIterable {
    case cell, useFor, hiddenAgents
}

/// The pane's open edits as a value: what a write is built from, and how a
/// write's revision is judged against them.
public struct LeoDelegationEdits: Equatable, Sendable {
    public var cell: LeoDelegationCellEditor?
    public var useFor: LeoDelegationUseForEditor?
    public var hiddenAgents: LeoDelegationHiddenAgentsEdit?

    public init(cell: LeoDelegationCellEditor? = nil, useFor: LeoDelegationUseForEditor? = nil, hiddenAgents: LeoDelegationHiddenAgentsEdit? = nil) {
        self.cell = cell
        self.useFor = useFor
        self.hiddenAgents = hiddenAgents
    }

    /// The revision a write is sent against: an edit's own base, else the document's.
    public func revision(for operation: LeoDelegationOperation, in document: LeoDelegationDocument) -> String {
        switch operation {
        case .cell: cell?.baseRevision ?? document.revision
        case .useFor: useFor?.baseRevision ?? document.revision
        case .hiddenAgents: hiddenAgents?.baseRevision ?? document.revision
        default: document.revision
        }
    }

    /// The open edits whose base is the revision a write was sent with (as the
    /// app's own writes have moved it on). Only these can follow that write
    /// onto the new document.
    public func editorsBased(on sent: String, revisions: LeoConfigRevisionTracker) -> Set<LeoDelegationEditor> {
        var matching: Set<LeoDelegationEditor> = []
        if let cell, revisions.resolve(cell.baseRevision) == sent { matching.insert(.cell) }
        if let useFor, revisions.resolve(useFor.baseRevision) == sent { matching.insert(.useFor) }
        if let hiddenAgents, revisions.resolve(hiddenAgents.baseRevision) == sent { matching.insert(.hiddenAgents) }
        return matching
    }
}
