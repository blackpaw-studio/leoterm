import Foundation

/// One value in a config document, in the daemon's JSON types (plan A4/A5).
/// A secret never carries its value: it reads as `{"set": bool}`, and is
/// written with `{"replace": …}` or `{"clear": true}`.
public enum LeoConfigValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([LeoConfigValue])
    /// An object whose values are all strings: an env map.
    case map([String: String])
    /// Any other object: a subsection, or `harness_options`.
    case object([String: LeoConfigValue])
    case secret(isSet: Bool)
    case secretReplace(String)
    case secretClear

    public var isNull: Bool { self == .null }

    /// Unset for a form's purposes: null, empty text, an empty list or map.
    /// Zero and `false` are real values.
    public var isBlank: Bool {
        switch self {
        case .null: true
        case .string(let text): text.isEmpty
        case .list(let values): values.isEmpty
        case .map(let entries): entries.isEmpty
        default: false
        }
    }

    /// Whether the two read the same on a form: equal, or both unset.
    public func isEquivalent(to other: LeoConfigValue) -> Bool {
        self == other || (isBlank && other.isBlank)
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var stringList: [String]? {
        guard case .list(let values) = self else { return nil }
        let strings = values.compactMap(\.stringValue)
        return strings.count == values.count ? strings : nil
    }

    /// The entries of an object; a string map reads as an object too.
    public var objectValue: [String: LeoConfigValue]? {
        switch self {
        case .object(let value): value
        case .map(let value): value.mapValues(LeoConfigValue.string)
        default: nil
        }
    }
}

extension LeoConfigValue {
    /// An env map's plain variables. The daemon reports a secret-valued
    /// variable as `{"set": true}`, never its value (`envSecretNames`).
    public var envEntries: [String: String] {
        objectValue?.compactMapValues(\.stringValue) ?? [:]
    }

    /// The env variables whose value the daemon holds back.
    public var envSecretNames: [String] {
        (objectValue ?? [:]).compactMap { entry in
            if case .secret = entry.value { entry.key } else { nil }
        }.sorted()
    }

    /// This map with its plain variables replaced by `entries`; its secret
    /// variables are carried along as they were (`{"set": true}` keeps one),
    /// unless `entries` names the same variable, which then wins.
    public func replacingEnvEntries(_ entries: [String: String]) -> LeoConfigValue {
        let secrets = (objectValue ?? [:]).filter { entry in
            if case .secret = entry.value { entries[entry.key] == nil } else { false }
        }
        guard !secrets.isEmpty else { return .map(entries) }
        return .object(entries.mapValues(LeoConfigValue.string).merging(secrets) { $1 })
    }
}

extension LeoConfigValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LeoConfigValue].self) {
            self = .list(value)
        } else {
            self = Self.classify(try container.decode([String: LeoConfigValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        case .map(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .secret(let isSet): try container.encode(["set": isSet])
        case .secretReplace(let value): try container.encode(["replace": value])
        case .secretClear: try container.encode(["clear": true])
        }
    }

    /// Reads an object as a secret form, a string map, or a general object.
    /// A string map `{"set": "yes"}` stays a map: only `{"set": <bool>}` is a secret.
    /// TODO: decoding should follow the schema's field type. Accepted risk
    /// until then: an env map whose only variable is named `set` (with a bool
    /// value), `replace` or `clear` reads as a secret.
    private static func classify(_ object: [String: LeoConfigValue]) -> Self {
        if object.count == 1, let (key, value) = object.first {
            switch (key, value) {
            case ("set", .bool(let isSet)): return .secret(isSet: isSet)
            case ("replace", .string(let text)): return .secretReplace(text)
            case ("clear", .bool(true)): return .secretClear
            default: break
            }
        }
        let strings = object.compactMapValues(\.stringValue)
        return strings.count == object.count ? .map(strings) : .object(object)
    }
}
