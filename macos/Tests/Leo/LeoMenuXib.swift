import AppKit

/// The main menu's key equivalents, read from the xib source
/// (instantiating MainMenu would also build its AppDelegate) or from a
/// live `NSMenu`, in one "⌃⌥⇧⌘key" form so one guard checks both.
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
            let flags: NSEvent.ModifierFlags = mask == nil ? .command : [
                has("control") ? .control : [], has("option") ? .option : [],
                has("shift") ? .shift : [], has("command") ? .command : [],
            ]
            let action = item.elements(forName: "connections").first?.elements(forName: "action").first?.attribute(forName: "selector")?.stringValue
            return MenuShortcut(title: item.attribute(forName: "title")?.stringValue ?? "", action: action, shortcut: shortcut(key, flags))
        }
    }

    /// Every item in `menu` (submenus included) with a key equivalent,
    /// hidden ones too.
    static func shortcuts(in menu: NSMenu?) -> [MenuShortcut] {
        (menu?.items ?? []).flatMap { item -> [MenuShortcut] in
            let own = item.keyEquivalent.isEmpty ? [] : [MenuShortcut(
                title: item.title,
                action: item.action.map(NSStringFromSelector),
                shortcut: shortcut(item.keyEquivalent, item.keyEquivalentModifierMask)
            )]
            return own + shortcuts(in: item.submenu)
        }
    }

    private static func shortcut(_ key: String, _ flags: NSEvent.ModifierFlags) -> String {
        let shift = flags.contains(.shift) || key != key.lowercased()
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (shift ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key.lowercased()
    }

    /// The items in `items` that break "only `owner` holds ⌘`key`": anyone
    /// else on ⌘`key`, and anyone at all -- `owner` included -- on a bare
    /// `key`, which is what an empty `<modifierMask/>` really binds (B-102).
    static func intruders(onCommand key: String, ownedBy owner: String, in items: [MenuShortcut]) -> [MenuShortcut] {
        items.filter { $0.shortcut == key || ($0.shortcut == "⌘" + key && $0.action != owner) }
    }
}
