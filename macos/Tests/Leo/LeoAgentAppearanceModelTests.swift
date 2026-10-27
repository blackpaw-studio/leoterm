import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The Appearance popover's logic: each pick is one manual write, the
/// selection shows at once and is reverted on a refusal, Reset clears both
/// values, and the source line says where each value comes from.
@MainActor
struct LeoAgentAppearanceModelTests {
    private static let homelab = LeoAppearanceRule(field: "environments", op: "contains", value: "homelab", color: "teal")
    private static let alfred = LeoAppearanceRule(field: "name", op: "glob", value: "olymp*", color: "pink", emoji: "🎩")

    private func fake(rules: [LeoAppearanceRule] = [homelab, alfred], manual: LeoAppearanceManual? = nil) async -> LeoFakeConfigClient {
        let fake = LeoFakeConfigClient(schema: LeoConfigSchema(resources: []))
        await fake.seedAppearance(
            agents: [LeoAppearanceFacts(name: "olympus", environments: ["homelab"], template: "ops", harness: "")],
            rules: rules, manual: manual.map { ["olympus": $0] } ?? [:]
        )
        return fake
    }

    private func model(_ client: LeoFakeConfigClient, appearance: LeoAgentAppearance?, defaults: UserDefaults? = nil) -> LeoAgentAppearanceModel {
        LeoAgentAppearanceModel(
            agent: "olympus", appearance: appearance, client: client,
            recents: LeoEmojiRecents(defaults: defaults ?? UserDefaults(suiteName: "leo.appearance.tests.\(UUID())")!)
        )
    }

    private static let fromRules = LeoAgentAppearance(emoji: "🎩", color: .teal, emojiSource: .rule(1), colorSource: .rule(0))

    @Test func pickEmojiWritesOnlyTheEmoji() async {
        let client = await fake()
        let model = model(client, appearance: Self.fromRules)
        await model.pickEmoji("🏛️")
        #expect(await client.calls.last == .setAgentAppearance(name: "olympus", emoji: .set("🏛️"), color: .unchanged))
        #expect(model.appearance == LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0)))
        #expect(model.error == nil)
    }

    @Test func pickColorAndNone() async {
        let client = await fake(rules: [])
        let model = model(client, appearance: nil)
        await model.pickColor(.indigo)
        #expect(await client.calls.last == .setAgentAppearance(name: "olympus", emoji: .unchanged, color: .set(.indigo)))
        #expect(model.appearance?.color == .indigo)
        await model.pickColor(nil)
        #expect(await client.calls.last == .setAgentAppearance(name: "olympus", emoji: .unchanged, color: .cleared))
        #expect(model.appearance == nil)
    }

    @Test func clearEmojiSendsNull() async {
        let client = await fake(rules: [], manual: LeoAppearanceManual(emoji: "🏛️", color: nil))
        let model = model(client, appearance: LeoAgentAppearance(emoji: "🏛️", color: nil, emojiSource: .manual))
        await model.clearEmoji()
        #expect(await client.calls.last == .setAgentAppearance(name: "olympus", emoji: .cleared, color: .unchanged))
        #expect(model.appearance == nil)
    }

    @Test func resetClearsBothAndIsOnlyOfferedForManualValues() async {
        let client = await fake(manual: LeoAppearanceManual(emoji: "🏛️", color: .red))
        let model = model(client, appearance: LeoAgentAppearance(emoji: "🏛️", color: .red, emojiSource: .manual, colorSource: .manual))
        #expect(model.canReset)
        await model.resetToRules()
        #expect(await client.calls.last == .setAgentAppearance(name: "olympus", emoji: .cleared, color: .cleared))
        #expect(model.appearance == Self.fromRules)
        #expect(!model.canReset)
    }

    @Test func sourceTextNamesTheRuleOnceRulesLoad() async {
        let model = model(await fake(), appearance: Self.fromRules)
        #expect(model.colorSourceText == "Teal from rule 1")
        await model.load()
        #expect(model.colorSourceText == "Teal from rule 1: environments contains homelab")
        #expect(model.emojiSourceText == "🎩 from rule 2: name matches olymp*")
    }

    @Test func sourceTextForManualAndUnset() async {
        let model = model(await fake(rules: []), appearance: LeoAgentAppearance(emoji: nil, color: .blue, colorSource: .manual))
        #expect(model.colorSourceText == "Blue, set on this agent")
        #expect(model.emojiSourceText == "No emoji")
        let none = self.model(await fake(rules: []), appearance: nil)
        #expect(none.colorSourceText == "No color")
    }

    @Test func refusalShowsTheErrorAndRevertsTheSelection() async {
        let client = await fake()
        await client.failNextWrite(with: LeoAppearanceError.invalidValue(field: "emoji", reason: "must be a single emoji"))
        let model = model(client, appearance: Self.fromRules)
        await model.pickEmoji("🏛️")
        #expect(model.appearance == Self.fromRules)
        #expect(model.error == "must be a single emoji")
        // The next successful write clears it.
        await model.pickColor(.green)
        #expect(model.error == nil)
    }

    @Test func feedUpdatesWinWhileIdle() async {
        let model = model(await fake(), appearance: nil)
        model.receive(Self.fromRules)
        #expect(model.appearance == Self.fromRules)
    }

    @Test func picksBecomeRecentEmoji() async {
        let defaults = UserDefaults(suiteName: "leo.appearance.tests.\(UUID())")!
        let model = model(await fake(), appearance: nil, defaults: defaults)
        await model.pickEmoji("🦊")
        await model.pickEmoji("🏛️")
        #expect(Array(model.frequent.map(\.emoji).prefix(2)) == ["🏛️", "🦊"])
        #expect(LeoEmojiRecents(defaults: defaults).emoji.prefix(2) == ["🏛️", "🦊"])
    }

    @Test func searchUsesTheCatalog() async {
        let model = model(await fake(), appearance: nil)
        #expect(model.results.isEmpty)
        model.query = "rocket"
        #expect(model.results.first?.emoji == "🚀")
    }
}
