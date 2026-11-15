import Foundation
import Testing

@testable import LeoKit

/// The picker's source line, "None" label and Reset rule, shared by the
/// Mac popover and the iOS sheet.
struct LeoAppearanceTextTests {
    private static let rules = [
        LeoAppearanceRule(when: .init(field: "environments", op: "contains", value: "homelab"), color: "teal"),
        LeoAppearanceRule(when: .init(field: "name", op: "glob", value: "olymp*"), emoji: "🎩"),
    ]
    private static let fromRules = LeoAgentAppearance(emoji: "🎩", color: .teal, emojiSource: .rule(1), colorSource: .rule(0))

    @Test func sourceLineNamesTheRuleOnceRulesAreKnown() {
        #expect(LeoAppearanceText.colorSource(Self.fromRules, rules: nil) == "Teal from rule 1")
        #expect(LeoAppearanceText.colorSource(Self.fromRules, rules: Self.rules) == "Teal from rule 1: environments contains homelab")
        #expect(LeoAppearanceText.emojiSource(Self.fromRules, rules: Self.rules) == "🎩 from rule 2: name matches olymp*")
    }

    @Test func sourceLineForManualUnsetAndOutOfRangeRules() {
        let manual = LeoAgentAppearance(emoji: nil, color: .blue, colorSource: .manual)
        #expect(LeoAppearanceText.colorSource(manual, rules: []) == "Blue, set on this agent")
        #expect(LeoAppearanceText.emojiSource(manual, rules: []) == "No emoji")
        #expect(LeoAppearanceText.colorSource(nil, rules: []) == "No color")
        let stale = LeoAgentAppearance(emoji: nil, color: .teal, colorSource: .rule(9))
        #expect(LeoAppearanceText.colorSource(stale, rules: Self.rules) == "Teal from rule 10")
    }

    @Test func noneLabelNamesTheRuleColorOrTheRulesOrNothing() {
        let manual = LeoAgentAppearance(emoji: nil, color: .purple, colorSource: .manual)
        #expect(LeoAppearanceText.noneColorLabel(Self.fromRules, rules: Self.rules) == "None, Teal from rule 1")
        #expect(LeoAppearanceText.noneColorLabel(manual, rules: Self.rules) == "None, use the rules")
        #expect(LeoAppearanceText.noneColorLabel(manual, rules: nil) == "None, use the rules", "rules unknown: assume one may give a color")
        #expect(LeoAppearanceText.noneColorLabel(manual, rules: []) == "None")
        #expect(LeoAppearanceText.noneColorLabel(nil, rules: []) == "None")
    }

    @Test func colorPickIsOnlyAHandSetColor() {
        #expect(LeoAppearanceText.colorPick(LeoAgentAppearance(emoji: nil, color: .purple, colorSource: .manual)) == .purple)
        #expect(LeoAppearanceText.colorPick(Self.fromRules) == nil)
        #expect(LeoAppearanceText.colorPick(nil) == nil)
    }

    @Test func resetIsOfferedOnlyForHandSetValues() {
        #expect(LeoAppearanceText.canReset(LeoAgentAppearance(emoji: "🏛️", color: nil, emojiSource: .manual)))
        #expect(LeoAppearanceText.canReset(LeoAgentAppearance(emoji: nil, color: .red, colorSource: .manual)))
        #expect(!LeoAppearanceText.canReset(Self.fromRules))
        #expect(!LeoAppearanceText.canReset(nil))
    }
}

extension LeoAppearanceTextTests {
    @Test func optimisticWriteShowsASetValueAsManualAndAClearedOneAsUnset() {
        let current = LeoAgentAppearance(emoji: "🎩", color: .teal, emojiSource: .rule(1), colorSource: .rule(0))

        let picked = LeoAppearanceText.optimistic(current, emoji: .set("🏛️"), color: .unchanged)
        #expect(picked == LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0)))

        let cleared = LeoAppearanceText.optimistic(current, emoji: .unchanged, color: .cleared)
        #expect(cleared == LeoAgentAppearance(emoji: "🎩", color: nil, emojiSource: .rule(1), colorSource: nil))
    }

    @Test func optimisticWriteThatEmptiesTheAppearanceIsNil() {
        let current = LeoAgentAppearance(emoji: "🏛️", color: nil, emojiSource: .manual)
        #expect(LeoAppearanceText.optimistic(current, emoji: .cleared, color: .unchanged) == nil)
        #expect(LeoAppearanceText.optimistic(nil, emoji: .unchanged, color: .cleared) == nil)
    }
}

struct LeoEmojiRecentsTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "leo.emoji.recents.tests.\(UUID())")! }

    @Test func newestFirstWithoutDuplicates() {
        let recents = LeoEmojiRecents(defaults: defaults())
        #expect(recents.emoji.isEmpty)
        recents.record("🏛️")
        recents.record("🦊")
        recents.record("🏛️")
        #expect(recents.emoji == ["🏛️", "🦊"])
    }

    @Test func keepsOnlyTheLimit() {
        let recents = LeoEmojiRecents(defaults: defaults())
        let many = ["😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃", "😉", "😊", "😇", "🥰", "😍", "🤩", "😘"]
        many.forEach(recents.record)
        #expect(recents.emoji.count == LeoEmojiRecents.limit)
        #expect(recents.emoji.first == "😘")
    }
}
