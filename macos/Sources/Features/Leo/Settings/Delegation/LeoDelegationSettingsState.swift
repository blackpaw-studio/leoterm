import LeoKit

/// An open cell popover: the cell being edited, the revision its base was
/// read at, and the daemon's complaints about the keys it last refused.
struct LeoDelegationCellEditor: Equatable {
    let profile: String
    let role: String
    var edit: LeoDelegationCellEdit
    var baseRevision: String
    /// By field (`template`, `model`, `effort`); `""` belongs to no field.
    var errors: [String: String] = [:]
}

/// An open edit of a declared role's description.
struct LeoDelegationUseForEditor: Equatable {
    let role: String
    var base: String
    var text: String
    var baseRevision: String
    var error: String?

    var isDirty: Bool { text != base }
}

/// The hide list being edited: the list as it was read and the one typed.
struct LeoDelegationHiddenAgentsEdit: Equatable {
    var base: [String]
    var names: [String]
    var baseRevision: String

    var isDirty: Bool { names != base }
}

/// The Make Active dialog: the daemon's account of what switching would change.
enum LeoDelegationPreviewState: Equatable {
    case loading(String)
    case loaded(LeoDelegationPreview)
    case failed(profile: String, message: String)

    var profile: String {
        switch self {
        case .loading(let profile), .failed(let profile, _): profile
        case .loaded(let preview): preview.profile
        }
    }
}

/// A question waiting on the user. Each names what the delete takes with it.
enum LeoDelegationConfirmation: Equatable {
    /// The role is removed from every profile that routes it.
    case deleteRole(name: String, profiles: [String])
    case deleteProfile(name: String, roleCount: Int)
}

/// A write the pane can send, kept so a conflict can be resolved by sending it again.
enum LeoDelegationOperation: Equatable {
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
    var isFormEdit: Bool {
        switch self {
        case .cell, .useFor, .hiddenAgents: true
        default: false
        }
    }

    /// A change of shape: it needs every form clean, and closes the clean ones.
    var changesStructure: Bool {
        switch self {
        case .addRole, .renameRole, .deleteRole, .addProfile, .renameProfile, .duplicateProfile, .deleteProfile: true
        default: false
        }
    }
}

/// The daemon's file moved on since the pane read it.
struct LeoDelegationConflict: Equatable {
    let operation: LeoDelegationOperation
    let currentRevision: String
}
