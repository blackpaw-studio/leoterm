import Foundation

/// One `appearance_rules` entry: `when` a field op value, set a color, an
/// emoji, or both. Field, op and color stay raw strings so a rule the daemon
/// reports as invalid (an unknown op, a color off the palette) round-trips
/// through the Settings editor unchanged; `problem` says what is wrong with
/// it, in the daemon's words.
public struct LeoAppearanceRule: Codable, Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case name, environments, template, harness
    }

    public enum Op: String, CaseIterable, Sendable {
        case `is`, contains
        case startsWith = "starts_with"
        case glob

        /// How a source line or rule summary says it.
        public var phrase: String {
            switch self {
            case .is: "is"
            case .contains: "contains"
            case .startsWith: "starts with"
            case .glob: "matches"
            }
        }
    }

    public struct Condition: Codable, Equatable, Sendable {
        public let field: String
        public let op: String
        public let value: String

        public init(field: String, op: String, value: String) {
            self.field = field
            self.op = op
            self.value = value
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            field = (try? container.decodeIfPresent(String.self, forKey: .field)) ?? ""
            op = (try? container.decodeIfPresent(String.self, forKey: .op)) ?? ""
            value = (try? container.decodeIfPresent(String.self, forKey: .value)) ?? ""
        }
    }

    public let when: Condition
    public let color: String?
    public let emoji: String?

    public init(when: Condition, color: String? = nil, emoji: String? = nil) {
        self.when = when
        self.color = color.flatMap { $0.isEmpty ? nil : $0 }
        self.emoji = emoji.flatMap { $0.isEmpty ? nil : $0 }
    }

    public init(field: String, op: String, value: String, color: String? = nil, emoji: String? = nil) {
        self.init(when: Condition(field: field, op: op, value: value), color: color, emoji: emoji)
    }

    enum CodingKeys: String, CodingKey { case when, color, emoji }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            when: (try? container.decodeIfPresent(Condition.self, forKey: .when)) ?? Condition(field: "", op: "", value: ""),
            color: (try? container.decodeIfPresent(String.self, forKey: .color)) ?? nil,
            emoji: (try? container.decodeIfPresent(String.self, forKey: .emoji)) ?? nil
        )
    }

    public var field: Field? { Field(rawValue: when.field) }
    public var op: Op? { Op(rawValue: when.op) }
    public var paletteColor: LeoAppearanceColor? { color.flatMap(LeoAppearanceColor.init(rawValue:)) }

    /// Why the rule is invalid, or nil. Mirrors leo `AppearanceRule.Problem`
    /// word for word, first problem first, so an inline message reads the
    /// same before and after a save.
    public var problem: String? {
        if field == nil {
            return "field \(Self.quoted(when.field)) must be one of \(Field.allCases.map(\.rawValue).joined(separator: ", "))"
        }
        if op == nil {
            return "op \(Self.quoted(when.op)) must be one of \(Op.allCases.map(\.rawValue).joined(separator: ", "))"
        }
        if when.value.isEmpty { return "value is required" }
        if op == .glob, when.value.contains(where: { "[]\\".contains($0) }) {
            return "glob \(Self.quoted(when.value)) may only use the * and ? wildcards"
        }
        if color == nil, emoji == nil { return "rule must set a color, an emoji, or both" }
        if let color, paletteColor == nil {
            return "color \(Self.quoted(color)) is not in the palette (\(LeoAppearanceColor.allCases.map(\.rawValue).joined(separator: ", ")))"
        }
        if let emoji, !LeoEmoji.isSingleGrapheme(emoji) {
            return "emoji \(Self.quoted(emoji)) must be a single emoji (one grapheme cluster of at most \(LeoEmoji.maxBytes) bytes)"
        }
        return nil
    }

    public var isValid: Bool { problem == nil }

    /// "environments contains homelab", for source lines and the rules list.
    public var summary: String {
        [when.field, op?.phrase ?? when.op, when.value].joined(separator: " ")
    }

    /// Go's `%q` for the strings a reason quotes: backslashes and quotes escaped.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// One invalid rule the daemon reported: its 0-based index and why.
public struct LeoAppearanceRuleProblem: Codable, Equatable, Sendable {
    public let index: Int
    public let reason: String

    public init(index: Int, reason: String) {
        self.index = index
        self.reason = reason
    }
}

/// `GET /appearance/rules` and a successful `PUT`: the rules in order, the
/// `leo.yaml` revision a write must name, and the rules invalid on disk.
public struct LeoAppearanceRulesDocument: Decodable, Equatable, Sendable {
    public let revision: String
    public let rules: [LeoAppearanceRule]
    public let errors: [LeoAppearanceRuleProblem]

    public init(revision: String, rules: [LeoAppearanceRule], errors: [LeoAppearanceRuleProblem] = []) {
        self.revision = revision
        self.rules = rules
        self.errors = errors
    }

    enum CodingKeys: String, CodingKey { case revision, rules, errors }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try container.decode(String.self, forKey: .revision),
            rules: try container.decodeIfPresent([LeoAppearanceRule].self, forKey: .rules) ?? [],
            errors: (try? container.decodeIfPresent([LeoAppearanceRuleProblem].self, forKey: .errors)) ?? []
        )
    }
}
