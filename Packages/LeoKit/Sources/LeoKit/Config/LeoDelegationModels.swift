import Foundation

/// A template a role can route to, with the model it brings.
public struct LeoDelegationTemplate: Decodable, Equatable, Sendable, Identifiable {
    public let name: String
    public let model: String

    public var id: String { name }

    public init(name: String, model: String) {
        self.name = name
        self.model = model
    }
}

/// A role the active profile routes. An undeclared role appears in some
/// profile's cells but not in `delegation.roles`, so it has no description.
public struct LeoDelegationRole: Decodable, Equatable, Sendable, Identifiable {
    public let name: String
    public let useFor: String
    public let declared: Bool

    public var id: String { name }

    public init(name: String, useFor: String = "", declared: Bool = true) {
        self.name = name
        self.useFor = useFor
        self.declared = declared
    }

    enum CodingKeys: String, CodingKey {
        case name, declared
        case useFor = "use_for"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            useFor: try container.decodeIfPresent(String.self, forKey: .useFor) ?? "",
            declared: try container.decodeIfPresent(Bool.self, forKey: .declared) ?? true
        )
    }
}

/// What one profile × role cell says: the template, and the model and effort
/// that override it (empty inherits). An empty template is no cell at all.
public struct LeoDelegationTarget: Decodable, Equatable, Hashable, Sendable {
    public var template: String
    public var model: String
    public var effort: String

    public init(template: String = "", model: String = "", effort: String = "") {
        self.template = template
        self.model = model
        self.effort = effort
    }

    enum CodingKeys: String, CodingKey { case template, model, effort }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            template: try container.decodeIfPresent(String.self, forKey: .template) ?? "",
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? "",
            effort: try container.decodeIfPresent(String.self, forKey: .effort) ?? ""
        )
    }
}

/// A cell as the document reads it: its target and the model its template
/// brings when the cell sets none.
public struct LeoDelegationCell: Decodable, Equatable, Hashable, Sendable {
    public let template: String
    public let model: String
    public let effort: String
    public let inheritedModel: String

    public init(template: String, model: String = "", effort: String = "", inheritedModel: String = "") {
        self.template = template
        self.model = model
        self.effort = effort
        self.inheritedModel = inheritedModel
    }

    public var target: LeoDelegationTarget { LeoDelegationTarget(template: template, model: model, effort: effort) }

    /// The model a dispatch through this cell uses: the override, else the template's.
    public var effectiveModel: String { model.isEmpty ? inheritedModel : model }

    enum CodingKeys: String, CodingKey {
        case template, model, effort
        case inheritedModel = "inherited_model"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            template: try container.decodeIfPresent(String.self, forKey: .template) ?? "",
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? "",
            effort: try container.decodeIfPresent(String.self, forKey: .effort) ?? "",
            inheritedModel: try container.decodeIfPresent(String.self, forKey: .inheritedModel) ?? ""
        )
    }
}

public struct LeoDelegationProfile: Decodable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    public let active: Bool
    /// By role name; a role with no entry is unmapped in this profile.
    public let roles: [String: LeoDelegationCell]

    public var id: String { name }

    public init(name: String, description: String = "", active: Bool = false, roles: [String: LeoDelegationCell] = [:]) {
        self.name = name
        self.description = description
        self.active = active
        self.roles = roles
    }

    enum CodingKeys: String, CodingKey { case name, description, active, roles }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            active: try container.decodeIfPresent(Bool.self, forKey: .active) ?? false,
            roles: try container.decodeIfPresent([String: LeoDelegationCell].self, forKey: .roles) ?? [:]
        )
    }
}

/// One role-routed consult as the recent-dispatches table shows it. The
/// daemon's record carries much more (prompt, text, tokens); none of it is read.
public struct LeoDelegationConsult: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let role: String
    public let profile: String
    public let template: String
    public let model: String
    public let effort: String
    public let status: String
    public let startedAt: Date?

    public init(
        id: String, role: String, profile: String = "", template: String = "", model: String = "", effort: String = "",
        status: String = "", startedAt: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.profile = profile
        self.template = template
        self.model = model
        self.effort = effort
        self.status = status
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, role, profile, template, model, effort, status
        case startedAt = "started_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            role: try container.decodeIfPresent(String.self, forKey: .role) ?? "",
            profile: try container.decodeIfPresent(String.self, forKey: .profile) ?? "",
            template: try container.decodeIfPresent(String.self, forKey: .template) ?? "",
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? "",
            effort: try container.decodeIfPresent(String.self, forKey: .effort) ?? "",
            status: try container.decodeIfPresent(String.self, forKey: .status) ?? "",
            startedAt: (try? Date(text, strategy: .iso8601)) ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
        )
    }
}

/// `GET /config/delegation`: the whole block, which is a grid rather than a
/// schema form. `configured: false` is a daemon with no `delegation:` block,
/// where every write is a 404 `delegation_not_configured`.
public struct LeoDelegationDocument: Decodable, Equatable, Sendable {
    public let revision: String
    public let configured: Bool
    public let enabled: Bool
    public let activeProfile: String
    public let hideNativeAgents: [String]
    /// The list is the daemon's built-in default, not one written to leo.yaml.
    public let hideNativeAgentsIsDefault: Bool
    public let templates: [LeoDelegationTemplate]
    public let roles: [LeoDelegationRole]
    public let profiles: [LeoDelegationProfile]
    public let warnings: [String]
    public let recentConsults: [LeoDelegationConsult]

    public init(
        revision: String, configured: Bool = true, enabled: Bool = true, activeProfile: String = "",
        hideNativeAgents: [String] = [], hideNativeAgentsIsDefault: Bool = false, templates: [LeoDelegationTemplate] = [],
        roles: [LeoDelegationRole] = [], profiles: [LeoDelegationProfile] = [], warnings: [String] = [],
        recentConsults: [LeoDelegationConsult] = []
    ) {
        self.revision = revision
        self.configured = configured
        self.enabled = enabled
        self.activeProfile = activeProfile
        self.hideNativeAgents = hideNativeAgents
        self.hideNativeAgentsIsDefault = hideNativeAgentsIsDefault
        self.templates = templates
        self.roles = roles
        self.profiles = profiles
        self.warnings = warnings
        self.recentConsults = recentConsults
    }

    enum CodingKeys: String, CodingKey {
        case revision, configured, enabled, templates, roles, profiles, warnings
        case activeProfile = "active_profile"
        case hideNativeAgents = "hide_native_agents"
        case hideNativeAgentsIsDefault = "hide_native_agents_is_default"
        case recentConsults = "recent_consults"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try container.decode(String.self, forKey: .revision),
            configured: try container.decodeIfPresent(Bool.self, forKey: .configured) ?? false,
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            activeProfile: try container.decodeIfPresent(String.self, forKey: .activeProfile) ?? "",
            hideNativeAgents: try container.decodeIfPresent([String].self, forKey: .hideNativeAgents) ?? [],
            hideNativeAgentsIsDefault: try container.decodeIfPresent(Bool.self, forKey: .hideNativeAgentsIsDefault) ?? false,
            templates: try container.decodeIfPresent([LeoDelegationTemplate].self, forKey: .templates) ?? [],
            roles: try container.decodeIfPresent([LeoDelegationRole].self, forKey: .roles) ?? [],
            profiles: try container.decodeIfPresent([LeoDelegationProfile].self, forKey: .profiles) ?? [],
            warnings: try container.decodeIfPresent([String].self, forKey: .warnings) ?? [],
            recentConsults: try container.decodeIfPresent([LeoDelegationConsult].self, forKey: .recentConsults) ?? []
        )
    }
}

/// `GET /config/delegation/preview?profile=`: what making a profile active
/// changes against the active one, and the declared roles it leaves unrouted.
public struct LeoDelegationPreview: Decodable, Equatable, Sendable {
    public struct Change: Decodable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case added, removed, changed
        }

        public let role: String
        public let kind: Kind
        public let before: LeoDelegationTarget
        public let after: LeoDelegationTarget

        public var id: String { role }

        public init(role: String, kind: Kind, before: LeoDelegationTarget, after: LeoDelegationTarget) {
            self.role = role
            self.kind = kind
            self.before = before
            self.after = after
        }

        enum CodingKeys: String, CodingKey { case role, kind, before, after }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                role: try container.decode(String.self, forKey: .role),
                kind: Kind(rawValue: try container.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .changed,
                before: try container.decodeIfPresent(LeoDelegationTarget.self, forKey: .before) ?? LeoDelegationTarget(),
                after: try container.decodeIfPresent(LeoDelegationTarget.self, forKey: .after) ?? LeoDelegationTarget()
            )
        }
    }

    public let profile: String
    public let changes: [Change]
    public let missing: [String]

    public init(profile: String, changes: [Change] = [], missing: [String] = []) {
        self.profile = profile
        self.changes = changes
        self.missing = missing
    }

    enum CodingKeys: String, CodingKey { case profile, changes, missing }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            profile: try container.decode(String.self, forKey: .profile),
            changes: try container.decodeIfPresent([Change].self, forKey: .changes) ?? [],
            missing: try container.decodeIfPresent([String].self, forKey: .missing) ?? []
        )
    }
}

/// The reply to a delegation write: like `LeoConfigWriteResult`, but its
/// `item` is the refreshed delegation document.
public struct LeoDelegationWriteResult: Decodable, Equatable, Sendable {
    public let revision: String
    public let restartRequired: LeoConfigRestartRequired
    public let warning: String?
    public let item: LeoDelegationDocument?

    public init(
        revision: String, restartRequired: LeoConfigRestartRequired = LeoConfigRestartRequired(),
        warning: String? = nil, item: LeoDelegationDocument? = nil
    ) {
        self.revision = revision
        self.restartRequired = restartRequired
        self.warning = warning
        self.item = item
    }

    enum CodingKeys: String, CodingKey {
        case revision, warning, item
        case restartRequired = "restart_required"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try container.decode(String.self, forKey: .revision),
            restartRequired: try container.decodeIfPresent(LeoConfigRestartRequired.self, forKey: .restartRequired) ?? LeoConfigRestartRequired(),
            warning: try container.decodeIfPresent(String.self, forKey: .warning),
            item: try container.decodeIfPresent(LeoDelegationDocument.self, forKey: .item)
        )
    }
}
