import Foundation
import LeoKit

/// The Appearance popover's state for one agent. Every pick is one manual
/// write (`PUT /agents/{name}/appearance`) that shows at once and is put
/// back if the daemon refuses it; the feed's next value wins once nothing
/// is in flight. The rules are fetched on open only to name a rule in the
/// source line.
@MainActor final class LeoAgentAppearanceModel: ObservableObject {
    let agent: String
    @Published var query = ""
    @Published private(set) var appearance: LeoAgentAppearance?
    @Published private(set) var rules: [LeoAppearanceRule]?
    @Published private(set) var error: String?
    @Published private(set) var isSaving = false

    private let client: any LeoAppearanceAPI
    private let catalog: LeoEmojiCatalog
    private let recents: LeoEmojiRecents

    init(
        agent: String, appearance: LeoAgentAppearance?, client: any LeoAppearanceAPI,
        catalog: LeoEmojiCatalog = .standard, recents: LeoEmojiRecents
    ) {
        self.agent = agent
        self.appearance = appearance
        self.client = client
        self.catalog = catalog
        self.recents = recents
    }

    // MARK: Emoji

    var results: [LeoEmojiEntry] { catalog.search(query) }
    var frequent: [LeoEmojiEntry] { catalog.frequent(recent: recents.emoji) }
    var groups: [LeoEmojiGroup] { catalog.groups }

    // MARK: Source line

    var emojiSourceText: String {
        guard let emoji = appearance?.emoji else { return "No emoji" }
        return Self.sourceText(emoji, source: appearance?.emojiSource, rules: rules)
    }

    var colorSourceText: String {
        guard let color = appearance?.color else { return "No color" }
        return Self.sourceText(color.displayName, source: appearance?.colorSource, rules: rules)
    }

    /// "Teal, set on this agent" or "Teal from rule 2: environments contains
    /// homelab"; rules are numbered from 1, as the Settings list shows them.
    static func sourceText(_ value: String, source: LeoAgentAppearance.Source?, rules: [LeoAppearanceRule]?) -> String {
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
    var colorPick: LeoAppearanceColor? { appearance?.colorSource == .manual ? appearance?.color : nil }

    /// None clears this agent's pick and falls back to the rules, so it
    /// says what that gives: the rule's color when one shows, else "use the
    /// rules" while a hand-set color hides whether a rule would.
    var noneColorLabel: String {
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
    var canReset: Bool { appearance?.emojiSource == .manual || appearance?.colorSource == .manual }

    // MARK: Actions

    func load() async {
        rules = try? await client.appearanceRules().rules
    }

    /// The feed's latest value; ignored while a write is in flight, whose
    /// answer is newer.
    func receive(_ appearance: LeoAgentAppearance?) {
        guard !isSaving else { return }
        self.appearance = appearance
    }

    func pickEmoji(_ emoji: String) async {
        recents.record(emoji)
        await write(emoji: .set(emoji), color: .unchanged)
    }

    func clearEmoji() async { await write(emoji: .cleared, color: .unchanged) }

    /// Nil is None: it clears the manual color (a rule's color then shows).
    func pickColor(_ color: LeoAppearanceColor?) async {
        await write(emoji: .unchanged, color: color.map { .set($0) } ?? .cleared)
    }

    func resetToRules() async { await write(emoji: .cleared, color: .cleared) }

    private func write(emoji: LeoAppearanceChange<String>, color: LeoAppearanceChange<LeoAppearanceColor>) async {
        let before = appearance
        appearance = Self.optimistic(before, emoji: emoji, color: color)
        isSaving = true
        defer { isSaving = false }
        do {
            appearance = try await client.setAgentAppearance(name: agent, emoji: emoji, color: color).appearance
            error = nil
        } catch {
            appearance = before
            self.error = error.localizedDescription
        }
    }

    /// What a pick looks like before the daemon answers: a set value is
    /// manual; a cleared one is unset until the answer says what a rule gives.
    private static func optimistic(
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
