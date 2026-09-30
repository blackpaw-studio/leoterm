import Foundation

/// The main menu's key equivalents, read from the xib source
/// (instantiating MainMenu would also build its AppDelegate).
enum LeoMenuXib {
    struct MenuShortcut {
        let title: String
        let action: String?
        let shortcut: String
    }

    /// Every menu item in MainMenu.xib with a key equivalent.
    static func shortcuts() throws -> [MenuShortcut] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/MainMenu.xib")
        return try shortcuts(in: XMLDocument(contentsOf: url))
    }

    /// Every menu item in `document` with a key equivalent, as "⌃⌥⇧⌘key"
    /// (an uppercase key implies Shift). Masks decode as a compiled nib
    /// loads them (checked with ibtool + NSNib, B-076): no modifierMask
    /// element is ⌘, an empty `<modifierMask/>` is no modifiers at all.
    static func shortcuts(in document: XMLDocument) throws -> [MenuShortcut] {
        try document.nodes(forXPath: "//menuItem[@keyEquivalent]").compactMap { node in
            guard let item = node as? XMLElement, let key = item.attribute(forName: "keyEquivalent")?.stringValue, !key.isEmpty else { return nil }
            let mask = item.elements(forName: "modifierMask").first
            func has(_ name: String) -> Bool { mask?.attribute(forName: name)?.stringValue == "YES" }
            let shift = has("shift") || key != key.lowercased()
            let shortcut = (has("control") ? "⌃" : "") + (has("option") ? "⌥" : "") + (shift ? "⇧" : "") + (has("command") || mask == nil ? "⌘" : "") + key.lowercased()
            let action = item.elements(forName: "connections").first?.elements(forName: "action").first?.attribute(forName: "selector")?.stringValue
            return MenuShortcut(title: item.attribute(forName: "title")?.stringValue ?? "", action: action, shortcut: shortcut)
        }
    }

    /// The items in `items` bound to any of `shortcuts` whose action isn't `owner`.
    static func claims(on shortcuts: Set<String>, byAnyoneBut owner: String, in items: [MenuShortcut]) -> [MenuShortcut] {
        items.filter { shortcuts.contains($0.shortcut) && $0.action != owner }
    }
}
