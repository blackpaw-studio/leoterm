import Foundation

/// The emoji this user picked last, newest first, for the picker's
/// frequent row. Per app install, not per machine.
struct LeoEmojiRecents {
    static let key = "leo.appearance.recentEmoji"
    static let limit = 16

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var emoji: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func record(_ emoji: String) {
        defaults.set(Array(([emoji] + self.emoji.filter { $0 != emoji }).prefix(Self.limit)), forKey: Self.key)
    }
}
