import Foundation

/// The daemon's field schema (`GET /config/schema`, plan A4): the resources
/// the settings window edits and the fields each one renders. Decoding is
/// tolerant by design: a newer daemon's extra keys, kinds, actions and field
/// types never fail it, so the app renders what it knows.
public struct LeoConfigSchema: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    /// The pattern a resource name must match, when the daemon sends one.
    public let namePattern: String?
    public let resources: [LeoConfigResource]
    /// Per-harness option fields, keyed by harness name.
    public let harnesses: [String: LeoConfigHarnessSchema]

    public init(schemaVersion: Int = 1, namePattern: String? = nil, resources: [LeoConfigResource], harnesses: [String: LeoConfigHarnessSchema] = [:]) {
        self.schemaVersion = schemaVersion
        self.namePattern = namePattern
        self.resources = resources
        self.harnesses = harnesses
    }

    public func resource(_ key: String) -> LeoConfigResource? {
        resources.first { $0.key == key }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case namePattern = "name_pattern"
        case resources, harnesses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        namePattern = try container.decodeIfPresent(String.self, forKey: .namePattern).flatMap { $0.isEmpty ? nil : $0 }
        resources = try container.decodeIfPresent([LeoConfigResource].self, forKey: .resources) ?? []
        harnesses = try container.decodeIfPresent([String: LeoConfigHarnessSchema].self, forKey: .harnesses) ?? [:]
    }
}

public struct LeoConfigHarnessSchema: Decodable, Equatable, Sendable {
    public let fields: [LeoConfigField]

    public init(fields: [LeoConfigField]) {
        self.fields = fields
    }

    enum CodingKeys: String, CodingKey { case fields }

    public init(from decoder: Decoder) throws {
        fields = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([LeoConfigField].self, forKey: .fields) ?? []
    }
}

public enum LeoConfigResourceKind: Equatable, Sendable {
    case singleton
    case collection
    case other(String)
}

/// What a collection's list can do. An action this app doesn't know is dropped.
public enum LeoConfigAction: String, Equatable, Sendable {
    case add, rename, duplicate, delete
}

/// Which restart a change needs: none (a reload covers it), the agents, or
/// the daemon service. A scope this app doesn't know is kept as `.other`.
public enum LeoConfigRestartScope: Equatable, Sendable {
    case none
    case agents
    case service
    case other(String)
}

public struct LeoConfigResource: Decodable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let kind: LeoConfigResourceKind
    public let section: String
    public let actions: [LeoConfigAction]
    public let harnessOptions: Bool
    public let restart: LeoConfigRestartScope
    public let fields: [LeoConfigField]
    public let subsections: [LeoConfigSubsection]

    public init(
        key: String, label: String? = nil, kind: LeoConfigResourceKind = .singleton, section: String? = nil,
        actions: [LeoConfigAction] = [], harnessOptions: Bool = false, restart: LeoConfigRestartScope = .none,
        fields: [LeoConfigField] = [], subsections: [LeoConfigSubsection] = []
    ) {
        self.key = key
        self.label = label ?? key
        self.kind = kind
        self.section = section ?? key
        self.actions = actions
        self.harnessOptions = harnessOptions
        self.restart = restart
        self.fields = fields
        self.subsections = subsections
    }

    public func field(_ key: String) -> LeoConfigField? {
        fields.first { $0.key == key }
    }

    public func supports(_ action: LeoConfigAction) -> Bool {
        actions.contains(action)
    }

    enum CodingKeys: String, CodingKey {
        case key, label, kind, section, actions, restart, fields, subsections
        case harnessOptions = "harness_options"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        self.init(
            key: key,
            label: try container.decodeIfPresent(String.self, forKey: .label),
            kind: try container.decodeIfPresent(LeoConfigResourceKind.self, forKey: .kind) ?? .singleton,
            section: try container.decodeIfPresent(String.self, forKey: .section),
            actions: (try container.decodeIfPresent([String].self, forKey: .actions) ?? []).compactMap(LeoConfigAction.init(rawValue:)),
            harnessOptions: try container.decodeIfPresent(Bool.self, forKey: .harnessOptions) ?? false,
            restart: try container.decodeIfPresent(LeoConfigRestartScope.self, forKey: .restart) ?? .none,
            fields: try container.decodeIfPresent([LeoConfigField].self, forKey: .fields) ?? [],
            subsections: try container.decodeIfPresent([LeoConfigSubsection].self, forKey: .subsections) ?? []
        )
    }
}

/// A nested block of a resource's form (`permissions`, `push`). Its values
/// nest under `key` in the document.
public struct LeoConfigSubsection: Decodable, Equatable, Sendable {
    public let key: String
    public let section: String
    public let fields: [LeoConfigField]

    public init(key: String, section: String? = nil, fields: [LeoConfigField] = []) {
        self.key = key
        self.section = section ?? key
        self.fields = fields
    }

    enum CodingKeys: String, CodingKey { case key, section, fields }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            section: try container.decodeIfPresent(String.self, forKey: .section),
            fields: try container.decodeIfPresent([LeoConfigField].self, forKey: .fields) ?? []
        )
    }
}

public enum LeoConfigFieldType: Equatable, Sendable {
    case string
    case int
    case bool
    case `enum`
    case list
    case map
    case duration
    case secret
    case reference
    case yaml
    /// A type this app doesn't know: shown read-only with a web UI link.
    case unknown(String)
}

public struct LeoConfigOption: Decodable, Equatable, Sendable {
    public let value: String
    public let label: String

    public init(value: String, label: String? = nil) {
        self.value = value
        self.label = label ?? value
    }

    enum CodingKeys: String, CodingKey { case value, label }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            value: try container.decode(String.self, forKey: .value),
            label: try container.decodeIfPresent(String.self, forKey: .label)
        )
    }
}

/// Where the daemon enforces a rule, the app checks it too (the daemon
/// stays authoritative).
public struct LeoConfigConstraints: Decodable, Equatable, Sendable {
    public let required: Bool
    public let min: Int?
    public let max: Int?
    public let pattern: String?

    public init(required: Bool = false, min: Int? = nil, max: Int? = nil, pattern: String? = nil) {
        self.required = required
        self.min = min
        self.max = max
        self.pattern = pattern
    }

    enum CodingKeys: String, CodingKey { case required, min, max, pattern }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            required: try container.decodeIfPresent(Bool.self, forKey: .required) ?? false,
            min: try? container.decodeIfPresent(Int.self, forKey: .min),
            max: try? container.decodeIfPresent(Int.self, forKey: .max),
            pattern: try container.decodeIfPresent(String.self, forKey: .pattern)
        )
    }
}

/// Model-field hints for one harness: suggestions to pick from, or a
/// placeholder when the harness has no stable list.
public struct LeoConfigHints: Decodable, Equatable, Sendable {
    public let suggestions: [String]
    public let placeholder: String?

    public init(suggestions: [String] = [], placeholder: String? = nil) {
        self.suggestions = suggestions
        self.placeholder = placeholder
    }

    enum CodingKeys: String, CodingKey { case suggestions, placeholder }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            suggestions: try container.decodeIfPresent([String].self, forKey: .suggestions) ?? [],
            placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder)
        )
    }
}

public struct LeoConfigField: Decodable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let help: String
    public let warning: String
    public let group: String
    public let advanced: Bool
    public let type: LeoConfigFieldType
    /// The value in effect when unset; `.null` when the daemon names none.
    public let defaultValue: LeoConfigValue
    public let constraints: LeoConfigConstraints
    public let restart: LeoConfigRestartScope
    public let multiline: Bool
    /// A format hint on a string, such as `"cron"`.
    public let format: String?
    /// A bool that may be unset, meaning inherit.
    public let nullable: Bool
    public let options: [LeoConfigOption]
    /// The collection a `reference` points at.
    public let references: String?
    /// The label of the empty choice on a `reference`.
    public let emptyLabel: String?
    public let hintsByHarness: [String: LeoConfigHints]

    public init(
        key: String, label: String? = nil, help: String = "", warning: String = "", group: String = "",
        advanced: Bool = false, type: LeoConfigFieldType, defaultValue: LeoConfigValue = .null,
        constraints: LeoConfigConstraints = LeoConfigConstraints(), restart: LeoConfigRestartScope = .none,
        multiline: Bool = false, format: String? = nil, nullable: Bool = false, options: [LeoConfigOption] = [],
        references: String? = nil, emptyLabel: String? = nil, hintsByHarness: [String: LeoConfigHints] = [:]
    ) {
        self.key = key
        self.label = label ?? key
        self.help = help
        self.warning = warning
        self.group = group
        self.advanced = advanced
        self.type = type
        self.defaultValue = defaultValue
        self.constraints = constraints
        self.restart = restart
        self.multiline = multiline
        self.format = format
        self.nullable = nullable
        self.options = options
        self.references = references
        self.emptyLabel = emptyLabel
        self.hintsByHarness = hintsByHarness
    }

    enum CodingKeys: String, CodingKey {
        case key, label, help, warning, group, advanced, type, constraints, restart, multiline, format, nullable, options, references
        case defaultValue = "default"
        case emptyLabel = "empty_label"
        case hintsByHarness = "hints_by_harness"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            label: try container.decodeIfPresent(String.self, forKey: .label),
            help: try container.decodeIfPresent(String.self, forKey: .help) ?? "",
            warning: try container.decodeIfPresent(String.self, forKey: .warning) ?? "",
            group: try container.decodeIfPresent(String.self, forKey: .group) ?? "",
            advanced: try container.decodeIfPresent(Bool.self, forKey: .advanced) ?? false,
            type: try container.decode(LeoConfigFieldType.self, forKey: .type),
            defaultValue: try container.decodeIfPresent(LeoConfigValue.self, forKey: .defaultValue) ?? .null,
            constraints: try container.decodeIfPresent(LeoConfigConstraints.self, forKey: .constraints) ?? LeoConfigConstraints(),
            restart: try container.decodeIfPresent(LeoConfigRestartScope.self, forKey: .restart) ?? .none,
            multiline: try container.decodeIfPresent(Bool.self, forKey: .multiline) ?? false,
            format: try container.decodeIfPresent(String.self, forKey: .format),
            nullable: try container.decodeIfPresent(Bool.self, forKey: .nullable) ?? false,
            options: try container.decodeIfPresent([LeoConfigOption].self, forKey: .options) ?? [],
            references: try container.decodeIfPresent(String.self, forKey: .references),
            emptyLabel: try container.decodeIfPresent(String.self, forKey: .emptyLabel),
            hintsByHarness: try container.decodeIfPresent([String: LeoConfigHints].self, forKey: .hintsByHarness) ?? [:]
        )
    }
}

extension LeoConfigResourceKind: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "singleton": self = .singleton
        case "collection": self = .collection
        default: self = .other(raw)
        }
    }
}

extension LeoConfigRestartScope: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard !container.decodeNil() else {
            self = .none
            return
        }
        let raw = try container.decode(String.self)
        switch raw {
        case "", "none": self = .none
        case "agents": self = .agents
        case "service": self = .service
        default: self = .other(raw)
        }
    }
}

extension LeoConfigFieldType: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "string": self = .string
        case "int": self = .int
        case "bool": self = .bool
        case "enum": self = .enum
        case "list": self = .list
        case "map": self = .map
        case "duration": self = .duration
        case "secret": self = .secret
        case "reference": self = .reference
        case "yaml": self = .yaml
        default: self = .unknown(raw)
        }
    }
}
