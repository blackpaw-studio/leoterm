import Foundation

/// What the appearance picker says about one agent: where each value comes
/// from, what "None" gives, and whether Reset means anything. Shared by the
/// Mac popover and the iOS sheet; `rules` is nil until they are fetched.
public enum LeoAppearanceText {
    public static func emojiSource(_ appearance: LeoAgentAppearance?, rules: [LeoAppearanceRule]?) -> String {
        guard let emoji = appearance?.emoji else { return "No emoji" }
        return sourceText(emoji, source: appearance?.emojiSource, rules: rules)
    }

    public static func colorSource(_ appearance: LeoAgentAppearance?, rules: [LeoAppearanceRule]?) -> String {
        guard let color = appearance?.color else { return "No color" }
        return sourceText(color.displayName, source: appearance?.colorSource, rules: rules)
    }

    /// "Teal, set on this agent" or "Teal from rule 2: environments contains
    /// homelab"; rules are numbered from 1, as the Settings list shows them.
    public static func sourceText(_ value: String, source: LeoAgentAppearance.Source?, rules: [LeoAppearanceRule]?) -> String {
        switch source {
        case .manual: return "\(value), set on this agent"
        case .rule(let index):
            let rule = rules.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            return "\(value) from rule \(index + 1)" + (rule.map { ": \($0.summary)" } ?? "")
        case nil: return value
        }
    }

    /// The swatch for this agent's own pick: None unless its color is set
    /// by hand, even while a rule's color shows.
    public static func colorPick(_ appearance: LeoAgentAppearance?) -> LeoAppearanceColor? {
        appearance?.colorSource == .manual ? appearance?.color : nil
    }

    /// None clears this agent's pick and falls back to the rules, so it
    /// says what that gives: the rule's color when one shows, else "use the
    /// rules" while a hand-set color hides whether a rule would.
    public static func noneColorLabel(_ appearance: LeoAgentAppearance?, rules: [LeoAppearanceRule]?) -> String {
        switch appearance?.colorSource {
        case .rule(let index):
            return "None, \(appearance?.color?.displayName ?? "") from rule \(index + 1)"
        case .manual where rules?.contains(where: { $0.color != nil }) ?? true:
            return "None, use the rules"
        case .manual, nil:
            return "None"
        }
    }

    /// Reset only means something while a value is set by hand.
    public static func canReset(_ appearance: LeoAgentAppearance?) -> Bool {
        appearance?.emojiSource == .manual || appearance?.colorSource == .manual
    }

    /// What a pick looks like before the daemon answers: a set value is
    /// manual; a cleared one is unset until the answer says what a rule gives.
    public static func optimistic(
        _ current: LeoAgentAppearance?, emoji: LeoAppearanceChange<String>, color: LeoAppearanceChange<LeoAppearanceColor>
    ) -> LeoAgentAppearance? {
        func source<Value>(_ change: LeoAppearanceChange<Value>, _ old: LeoAgentAppearance.Source?) -> LeoAgentAppearance.Source? {
            switch change {
            case .unchanged: old
            case .cleared: nil
            case .set: .manual
            }
        }
        let next = LeoAgentAppearance(
            emoji: emoji.applied(to: current?.emoji), color: color.applied(to: current?.color),
            emojiSource: source(emoji, current?.emojiSource), colorSource: source(color, current?.colorSource)
        )
        return next.isEmpty ? nil : next
    }
}
