import Foundation

/// The daemon's emoji rule (leo `ValidateAppearanceEmoji`): exactly one
/// grapheme cluster of at most `maxBytes` UTF-8 bytes. A ZWJ family, a flag,
/// a skin-toned or keycap emoji each count as one.
public enum LeoEmoji {
    public static let maxBytes = 64

    public static func isSingleGrapheme(_ text: String) -> Bool {
        text.count == 1 && text.utf8.count <= maxBytes
    }
}
