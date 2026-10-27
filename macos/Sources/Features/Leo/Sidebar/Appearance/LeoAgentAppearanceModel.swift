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

    var emojiSourceText: String { LeoAppearanceText.emojiSource(appearance, rules: rules) }
    var colorSourceText: String { LeoAppearanceText.colorSource(appearance, rules: rules) }
    var colorPick: LeoAppearanceColor? { LeoAppearanceText.colorPick(appearance) }
    var noneColorLabel: String { LeoAppearanceText.noneColorLabel(appearance, rules: rules) }
    var canReset: Bool { LeoAppearanceText.canReset(appearance) }

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
        appearance = LeoAppearanceText.optimistic(before, emoji: emoji, color: color)
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
}
