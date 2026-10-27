import ComposableArchitecture
import Foundation
import LeoKit

extension LeoEmojiRecents: DependencyKey {
    public static var liveValue: LeoEmojiRecents { LeoEmojiRecents(defaults: .standard) }

    /// An ephemeral store, so a test never reads or writes the real one.
    public static var testValue: LeoEmojiRecents { LeoEmojiRecents(defaults: UserDefaults(suiteName: "leo.emoji.recents.\(UUID())")!) }
}

extension DependencyValues {
    public var emojiRecents: LeoEmojiRecents {
        get { self[LeoEmojiRecents.self] }
        set { self[LeoEmojiRecents.self] = newValue }
    }
}
