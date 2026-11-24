import AppKit

/// What a dragged dock tab carries (B-440): its pane, under a private type
/// only the dock's drop overlay accepts. Nothing is written as text or a
/// file URL, which the terminal would take as a paste or a file drop.
enum LeoDockPaneDrag {
    static let pasteboardType = NSPasteboard.PasteboardType("studio.blackpaw.leo.dock-pane")

    /// How far the cursor moves from a tab's mouse-down before the press
    /// becomes a drag; under it, jitter is still a click.
    static let dragThreshold: CGFloat = 4

    /// The item a drag session carries for `pane`.
    static func item(for pane: LeoDockPane) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(pane.rawValue, forType: pasteboardType)
        return item
    }

    /// Replaces the pasteboard's contents with `pane`'s item.
    static func write(_ pane: LeoDockPane, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects([item(for: pane)])
    }

    /// The pane on the pasteboard; nil for anything else, a value this
    /// build doesn't know included.
    static func pane(from pasteboard: NSPasteboard) -> LeoDockPane? {
        pasteboard.string(forType: pasteboardType).flatMap(LeoDockPane.init(rawValue:))
    }
}
