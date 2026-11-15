import Foundation

/// A key chord as an agent writes it: `Enter`, `Meta+a`, `Control+Shift+ArrowLeft`.
/// `key` is a DOM `KeyboardEvent.key` value: a single character, or one of the
/// canonical names (`Enter`, `Escape`, `Tab`, `Backspace`, `Delete`, `ArrowUp`...,
/// `Home`, `End`, `PageUp`, `PageDown`, `F1`-`F12`). A space is `" "`.
public struct LeoBrowserKeyCombo: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let alt = Modifiers(rawValue: 4)
        public static let meta = Modifiers(rawValue: 8)
    }

    public let modifiers: Modifiers
    public let key: String

    public init(modifiers: Modifiers, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    private static let modifierNames: [String: Modifiers] = [
        "shift": .shift, "control": .control, "ctrl": .control, "alt": .alt, "option": .alt, "opt": .alt,
        "meta": .meta, "cmd": .meta, "command": .meta,
    ]

    private static let namedKeys: [String: String] = {
        var names = [
            "enter": "Enter", "return": "Enter", "escape": "Escape", "esc": "Escape", "tab": "Tab", "backspace": "Backspace",
            "delete": "Delete", "del": "Delete", "arrowup": "ArrowUp", "arrowdown": "ArrowDown", "arrowleft": "ArrowLeft",
            "arrowright": "ArrowRight", "home": "Home", "end": "End", "pageup": "PageUp", "pagedown": "PageDown", "space": " ",
        ]
        for number in 1...12 { names["f\(number)"] = "F\(number)" }
        return names
    }()

    /// nil for an empty chord, a chord with no key (`Meta+`, `Shift`), an
    /// unknown modifier or an unknown multi-character key name.
    public init?(_ text: String) {
        var body = text
        var parts: [String] = []
        // A trailing "+" is the plus key itself ("Meta++"), not a separator.
        var key: String?
        if body.hasSuffix("+") && body.count > 1 && body.dropLast().hasSuffix("+") {
            key = "+"
            body.removeLast(2)
            parts = body.isEmpty ? [] : body.components(separatedBy: "+")
        } else if body == "+" {
            key = "+"
        } else {
            parts = body.components(separatedBy: "+")
            key = parts.popLast()
        }
        var modifiers: Modifiers = []
        for part in parts {
            guard let modifier = Self.modifierNames[part.lowercased()] else { return nil }
            modifiers.insert(modifier)
        }
        guard let key, let resolved = Self.resolve(key) else { return nil }
        self.init(modifiers: modifiers, key: resolved)
    }

    private static func resolve(_ key: String) -> String? {
        if key.count == 1 { return key }
        return namedKeys[key.lowercased()]
    }
}
