import Foundation

/// One resource document (`GET /config/<singleton>` or
/// `GET /config/<collection>/<name>`): the values set on that scope, the
/// placeholders it inherits, and its revision.
public struct LeoConfigDocument: Decodable, Equatable, Sendable {
    /// The leo.yaml revision this was read at; a write sends it as `If-Match`.
    public let revision: String
    /// The item's name; nil for a singleton.
    public let name: String?
    /// Keyed by schema field key. Subsections nest under their key, and
    /// `harness_options` holds only the keys set on this scope.
    public let values: [String: LeoConfigValue]
    /// What an unset field falls back to (the defaults cascade).
    public let inherited: [String: LeoConfigValue]
    public let effectiveHarness: String?

    public init(
        revision: String, name: String? = nil, values: [String: LeoConfigValue],
        inherited: [String: LeoConfigValue] = [:], effectiveHarness: String? = nil
    ) {
        self.revision = revision
        self.name = name
        self.values = values
        self.inherited = inherited
        self.effectiveHarness = effectiveHarness
    }

    enum CodingKeys: String, CodingKey {
        case revision, name, values, inherited
        case effectiveHarness = "effective_harness"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try container.decode(String.self, forKey: .revision),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            values: try container.decodeIfPresent([String: LeoConfigValue].self, forKey: .values) ?? [:],
            inherited: try container.decodeIfPresent([String: LeoConfigValue].self, forKey: .inherited) ?? [:],
            effectiveHarness: (try? container.decodeIfPresent(String.self, forKey: .effectiveHarness)) ?? nil
        )
    }

    public var item: LeoConfigItem {
        LeoConfigItem(name: name ?? "", values: values, inherited: inherited, effectiveHarness: effectiveHarness)
    }
}

/// One entry of a collection listing: a document without its own revision.
public struct LeoConfigItem: Decodable, Equatable, Sendable, Identifiable {
    public let name: String
    public let values: [String: LeoConfigValue]
    public let inherited: [String: LeoConfigValue]
    public let effectiveHarness: String?

    public var id: String { name }

    public init(
        name: String, values: [String: LeoConfigValue], inherited: [String: LeoConfigValue] = [:],
        effectiveHarness: String? = nil
    ) {
        self.name = name
        self.values = values
        self.inherited = inherited
        self.effectiveHarness = effectiveHarness
    }

    enum CodingKeys: String, CodingKey {
        case name, values, inherited
        case effectiveHarness = "effective_harness"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            values: try container.decodeIfPresent([String: LeoConfigValue].self, forKey: .values) ?? [:],
            inherited: try container.decodeIfPresent([String: LeoConfigValue].self, forKey: .inherited) ?? [:],
            effectiveHarness: (try? container.decodeIfPresent(String.self, forKey: .effectiveHarness)) ?? nil
        )
    }
}

/// `GET /config/<collection>`: every item, sorted by name, in one call.
public struct LeoConfigCollection: Decodable, Equatable, Sendable {
    public let revision: String
    public let items: [LeoConfigItem]

    public init(revision: String, items: [LeoConfigItem]) {
        self.revision = revision
        self.items = items
    }
}

/// Which restarts the daemon says a write left pending.
public struct LeoConfigRestartRequired: Decodable, Equatable, Sendable {
    public let service: Bool
    public let agents: Bool

    public var isNeeded: Bool { service || agents }

    public init(service: Bool = false, agents: Bool = false) {
        self.service = service
        self.agents = agents
    }

    enum CodingKeys: String, CodingKey { case service, agents }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            service: try container.decodeIfPresent(Bool.self, forKey: .service) ?? false,
            agents: try container.decodeIfPresent(Bool.self, forKey: .agents) ?? false
        )
    }
}

/// The reply to a config write (plan A6).
public struct LeoConfigWriteResult: Decodable, Equatable, Sendable {
    /// The revision after the write.
    public let revision: String
    public let restartRequired: LeoConfigRestartRequired
    /// Saved, but the daemon's reload failed.
    public let warning: String?
    /// The item written, on an add or duplicate.
    public let item: LeoConfigDocument?

    public init(
        revision: String, restartRequired: LeoConfigRestartRequired = LeoConfigRestartRequired(),
        warning: String? = nil, item: LeoConfigDocument? = nil
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
            item: try container.decodeIfPresent(LeoConfigDocument.self, forKey: .item)
        )
    }
}
