import Foundation

/// The emoji this user picked last, newest first, for the picker's
/// frequent row. Per app install, not per machine.
public struct LeoEmojiRecents: @unchecked Sendable {
    public static let key = "leo.appearance.recentEmoji"
    public static let limit = 16

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var emoji: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    public func record(_ emoji: String) {
        defaults.set(Array(([emoji] + self.emoji.filter { $0 != emoji }).prefix(Self.limit)), forKey: Self.key)
    }
}
