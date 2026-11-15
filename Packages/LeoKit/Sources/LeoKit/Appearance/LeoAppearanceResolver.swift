import Foundation

/// The agent facts an appearance rule tests. `environments` is the agent's
/// effective list, as the observe wire reports it; an empty `harness` is
/// `claude`, as on the daemon.
public struct LeoAppearanceFacts: Equatable, Sendable {
    public static let defaultHarness = "claude"

    public let name: String
    public let environments: [String]
    public let template: String
    public let harness: String

    public init(name: String, environments: [String], template: String, harness: String) {
        self.name = name
        self.environments = environments
        self.template = template
        self.harness = harness.isEmpty ? Self.defaultHarness : harness
    }
}

/// An agent's hand-set values, the ones `PUT /agents/{name}/appearance` writes.
public struct LeoAppearanceManual: Equatable, Sendable {
    public let emoji: String?
    public let color: LeoAppearanceColor?

    public init(emoji: String?, color: LeoAppearanceColor?) {
        self.emoji = emoji.flatMap { $0.isEmpty ? nil : $0 }
        self.color = color
    }
}

/// leo `ResolveAppearance`, for the Settings preview, match counts and source
/// text only: the daemon stays authoritative for what a row shows. Color and
/// emoji resolve independently: the manual value wins, else the first valid
/// matching rule from the top that sets it, else unset. An invalid rule is
/// skipped without shifting later indices.
public enum LeoAppearanceResolver {
    public static func resolve(rules: [LeoAppearanceRule], facts: LeoAppearanceFacts, manual: LeoAppearanceManual?) -> LeoAgentAppearance? {
        let start = Partial(emoji: manual?.emoji.map { ($0, .manual) }, color: manual?.color.map { ($0, .manual) })
        let resolved = rules.enumerated().reduce(start) { partial, entry in
            let (index, rule) = entry
            guard partial.emoji == nil || partial.color == nil, rule.matches(facts) else { return partial }
            return Partial(
                emoji: partial.emoji ?? rule.emoji.map { ($0, .rule(index)) },
                color: partial.color ?? rule.paletteColor.map { ($0, .rule(index)) }
            )
        }
        let appearance = LeoAgentAppearance(
            emoji: resolved.emoji?.0, color: resolved.color?.0, emojiSource: resolved.emoji?.1, colorSource: resolved.color?.1
        )
        return appearance.isEmpty ? nil : appearance
    }

    private struct Partial {
        let emoji: (String, LeoAgentAppearance.Source)?
        let color: (LeoAppearanceColor, LeoAgentAppearance.Source)?
    }
}

extension LeoAppearanceRule {
    /// Whether `facts` satisfy this rule; an invalid rule never matches.
    /// Case-sensitive. On `environments`, `is` and `contains` test
    /// membership, and `starts_with` and `glob` match when any element does.
    public func matches(_ facts: LeoAppearanceFacts) -> Bool {
        guard isValid, let field, let op else { return false }
        switch field {
        case .environments: return facts.environments.contains { Self.match(op, $0, when.value, isElement: true) }
        case .name: return Self.match(op, facts.name, when.value, isElement: false)
        case .template: return Self.match(op, facts.template, when.value, isElement: false)
        case .harness: return Self.match(op, facts.harness, when.value, isElement: false)
        }
    }

    private static func match(_ op: Op, _ text: String, _ value: String, isElement: Bool) -> Bool {
        switch op {
        case .is: text == value
        case .contains: isElement ? text == value : text.contains(value)
        case .startsWith: text.hasPrefix(value)
        case .glob: globMatch(Array(value.unicodeScalars), Array(text.unicodeScalars))
        }
    }

    /// leo `globMatch`: the whole string, `*` any run of code points
    /// (slashes included), `?` exactly one, everything else itself.
    static func globMatch(_ pattern: [Unicode.Scalar], _ text: [Unicode.Scalar]) -> Bool {
        var (pi, ti, star, mark) = (0, 0, -1, 0)
        while ti < text.count {
            if pi < pattern.count, pattern[pi] == "*" {
                (star, mark) = (pi, ti)
                pi += 1
            } else if pi < pattern.count, pattern[pi] == "?" || pattern[pi] == text[ti] {
                pi += 1
                ti += 1
            } else if star >= 0 {
                mark += 1
                (pi, ti) = (star + 1, mark)
            } else {
                return false
            }
        }
        while pi < pattern.count, pattern[pi] == "*" { pi += 1 }
        return pi == pattern.count
    }
}
