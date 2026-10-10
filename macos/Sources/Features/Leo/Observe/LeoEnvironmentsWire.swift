import Foundation

/// An agent's effective named environments (B-283, leo `agent_environments`):
/// the ordered names, whether they are the agent's own override or the
/// template/global default, and a config problem the daemon reported.
/// Names only: an environment's values never reach the app.
struct LeoAgentEnvironments: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case override
        case `default`
    }

    let names: [String]
    /// Nil when the daemon sent none (or one this app doesn't know).
    let source: Source?
    /// e.g. a name deleted from config; nil when there is none.
    let error: String?

    static let empty = LeoAgentEnvironments(names: [], source: nil, error: nil)

    var isOverride: Bool { source == .override }
}

/// The environment fields of one event. Each field is three-state: absent
/// leaves the value unchanged (a lifecycle `agent_state_changed` omits
/// them), an explicit null clears it, and a value sets it.
struct LeoAgentEnvironmentsPatch: Equatable, Sendable {
    enum Field<Value: Equatable & Sendable>: Equatable, Sendable {
        case unchanged
        case cleared
        case set(Value)

        func applied(to current: Value?) -> Value? {
            switch self {
            case .unchanged: current
            case .cleared: nil
            case .set(let value): value
            }
        }
    }

    let names: Field<[String]>
    let source: Field<LeoAgentEnvironments.Source>
    let error: Field<String>

    func applied(to current: LeoAgentEnvironments?) -> LeoAgentEnvironments {
        let base = current ?? .empty
        return LeoAgentEnvironments(
            names: names.applied(to: base.names) ?? [],
            source: source.applied(to: base.source),
            error: error.applied(to: base.error)
        )
    }
}

/// The configured environment names and each template's default list, for
/// the spawn sheet and the Set Environments menu.
struct LeoEnvironmentCatalog: Equatable, Sendable {
    /// Alphabetical.
    let names: [String]
    /// Template name -> its default list; `[]` when the template sets none
    /// (the daemon's global default then applies).
    let templateDefaults: [String: [String]]

    init(names: [String], templateDefaults: [String: [String]] = [:]) {
        self.names = names.sorted()
        self.templateDefaults = templateDefaults
    }

    func defaults(for template: String) -> [String] { templateDefaults[template] ?? [] }
}

/// The only place that knows the named-environment wire format (leo PR
/// #251): key names, socket routes, and the request bodies. A rename in the
/// daemon is a one-line change here. Values are never decoded.
enum LeoEnvironmentsWire {
    static let namesKey = "environments"
    static let sourceKey = "environments_source"
    static let errorKey = "environment_error"
    static let spawnKey = "environments"
    static let catalogRoute = "/environments"
    static let templatesRoute = "/templates"
    static let agentAction = "environments"

    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    /// An agent object's fields (`/state`). Nil when the daemon sent no
    /// names, or malformed ones; never throws, so `/state` never fails.
    static func agent(from decoder: any Decoder) -> LeoAgentEnvironments? {
        guard let container = try? decoder.container(keyedBy: Key.self),
              let names = try? container.decode([String].self, forKey: Key(stringValue: namesKey)) else { return nil }
        let source = (try? container.decode(String.self, forKey: Key(stringValue: sourceKey))).flatMap(LeoAgentEnvironments.Source.init(rawValue:))
        let error = (try? container.decodeIfPresent(String.self, forKey: Key(stringValue: errorKey))) ?? nil
        return LeoAgentEnvironments(names: names, source: source, error: error)
    }

    /// An event's fields, read from its `nested` object (`agent` on
    /// `agent_spawned`) or else the payload itself. Nil when it carries none.
    static func patch(in data: Data, nested: String? = nil) -> LeoAgentEnvironmentsPatch? {
        struct Payload: Decodable {
            let patch: LeoAgentEnvironmentsPatch?
            init(from decoder: any Decoder) throws { patch = LeoEnvironmentsWire.patch(from: decoder) }
        }
        let decode = { (data: Data) in (try? JSONDecoder().decode(Payload.self, from: data))?.patch }
        if let nested, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = object[nested] as? [String: Any], let innerData = try? JSONSerialization.data(withJSONObject: inner),
           let patch = decode(innerData) {
            return patch
        }
        return decode(data)
    }

    private static func patch(from decoder: any Decoder) -> LeoAgentEnvironmentsPatch? {
        guard let container = try? decoder.container(keyedBy: Key.self) else { return nil }
        let names = field(container, namesKey, as: [String].self)
        let source = field(container, sourceKey, as: String.self)
        let error = field(container, errorKey, as: String.self)
        guard names != .unchanged || source != .unchanged || error != .unchanged else { return nil }
        let knownSource: LeoAgentEnvironmentsPatch.Field<LeoAgentEnvironments.Source> = switch source {
        case .unchanged: .unchanged
        case .cleared: .cleared
        case .set(let raw): LeoAgentEnvironments.Source(rawValue: raw).map { .set($0) } ?? .cleared
        }
        return LeoAgentEnvironmentsPatch(names: names, source: knownSource, error: error)
    }

    /// Absent or malformed -> unchanged; null -> cleared.
    private static func field<Value: Decodable & Equatable & Sendable>(
        _ container: KeyedDecodingContainer<Key>, _ name: String, as _: Value.Type
    ) -> LeoAgentEnvironmentsPatch.Field<Value> {
        let key = Key(stringValue: name)
        guard container.contains(key) else { return .unchanged }
        if (try? container.decodeNil(forKey: key)) == true { return .cleared }
        return (try? container.decode(Value.self, forKey: key)).map { .set($0) } ?? .unchanged
    }

    /// `GET /environments`: `[{"name": ...}]`, sorted here too.
    static func catalogNames(_ data: Data) throws -> [String] {
        struct Entry: Decodable, Sendable { let name: String }
        return try LeoDaemonEnvelope<[Entry]>.decode(data).value().map(\.name).sorted()
    }

    /// `GET /templates`: each template's `environments`; missing reads as `[]`.
    static func templateDefaults(_ data: Data) throws -> [String: [String]] {
        struct Entry: Decodable, Sendable {
            let name: String
            let environments: [String]?
        }
        let entries = try LeoDaemonEnvelope<[Entry]>.decode(data).value()
        return Dictionary(entries.map { ($0.name, $0.environments ?? []) }, uniquingKeysWith: { first, _ in first })
    }

    static func setBody(_ names: [String]) throws -> Data {
        try JSONEncoder().encode([namesKey: names])
    }

    /// The spawn body with `environments` added; unchanged when nil.
    static func spawnBody(_ request: LeoSpawnRequest) throws -> Data {
        let body = try JSONEncoder().encode(request)
        guard let names = request.environments else { return body }
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LeoDaemonError.decoding("Spawn request is not an object")
        }
        object[spawnKey] = names
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
