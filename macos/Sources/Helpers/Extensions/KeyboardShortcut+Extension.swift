import SwiftUI

extension KeyboardShortcut: @retroactive CustomStringConvertible {
    public var keyList: [String] {
        var result: [String] = []

        if modifiers.contains(.control) {
            result.append("⌃")
        }
        if modifiers.contains(.option) {
            result.append("⌥")
        }
        if modifiers.contains(.shift) {
            result.append("⇧")
        }
        if modifiers.contains(.command) {
            result.append("⌘")
        }

        let keyString: String
        switch key {
        case .return: keyString = "⏎"
        case .escape: keyString = "⎋"
        case .delete: keyString = "⌫"
        case .deleteForward: keyString = "⌦"
        case .space: keyString = "␣"
        case .tab: keyString = "⇥"
        case .upArrow: keyString = "▲"
        case .downArrow: keyString = "▼"
        case .leftArrow: keyString = "◀"
        case .rightArrow: keyString = "▶"
        case .pageUp: keyString = "↑"
        case .pageDown: keyString = "↓"
        case .home: keyString = "⤒"
        case .end: keyString = "⤓"
        default:
            keyString = key.functionKeyName ?? String(key.character.uppercased())
        }

        result.append(keyString)
        return result
    }

    public var description: String {
        return self.keyList.joined()
    }
}

extension KeyEquivalent {
    /// AppKit's F1…F35 key equivalents: consecutive private-use characters.
    private static let functionKeys = NSF1FunctionKey...NSF35FunctionKey

    /// "F1"…"F35" for AppKit's function-key characters, else nil.
    var functionKeyName: String? {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
              Self.functionKeys.contains(Int(scalar.value)) else { return nil }
        return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
    }
}

// This is available in macOS 14 so this only applies to early macOS versions.
extension KeyEquivalent: @retroactive Equatable {
    public static func == (lhs: KeyEquivalent, rhs: KeyEquivalent) -> Bool {
        lhs.character == rhs.character
    }
}
