import Foundation

/// The main menu's key equivalents, read from the xib source
/// (instantiating MainMenu would also build its AppDelegate).
enum LeoMenuXib {
    struct MenuShortcut {
        let title: String
        let action: String?
        let shortcut: String
    }

    /// Every menu item with a key equivalent, as "⌃⌥⇧⌘key" (an uppercase
    /// key implies Shift).
    static func shortcuts() throws -> [MenuShortcut] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/MainMenu.xib")
        let document = try XMLDocument(contentsOf: url)
        return try document.nodes(forXPath: "//menuItem[@keyEquivalent]").compactMap { node in
            guard let item = node as? XMLElement, let key = item.attribute(forName: "keyEquivalent")?.stringValue, !key.isEmpty else { return nil }
            // No modifierMask element at all is IB's default: ⌘.
            let mask = item.elements(forName: "modifierMask").first
            func has(_ name: String) -> Bool { mask?.attribute(forName: name)?.stringValue == "YES" }
            let shift = has("shift") || key != key.lowercased()
            let shortcut = (has("control") ? "⌃" : "") + (has("option") ? "⌥" : "") + (shift ? "⇧" : "") + (has("command") || mask == nil ? "⌘" : "") + key.lowercased()
            let action = item.elements(forName: "connections").first?.elements(forName: "action").first?.attribute(forName: "selector")?.stringValue
            return MenuShortcut(title: item.attribute(forName: "title")?.stringValue ?? "", action: action, shortcut: shortcut)
        }
    }
}
