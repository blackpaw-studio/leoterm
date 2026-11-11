import Foundation
import LeoKit

/// Keys the list handles itself.
enum LeoPluginListKey: Equatable {
    case `return`
    case commandReturn
}

/// Which table rows changed after a diff, so the view can edit in place
/// (keeping scroll and selection) instead of reloading.
struct LeoPluginRowChange: Equatable {
    /// Indexes in the old row list.
    var removed: IndexSet = []
    /// Indexes in the new row list.
    var inserted: IndexSet = []
    var updated: IndexSet = []

    var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && updated.isEmpty }
}

struct LeoPluginActionPanelState: Equatable {
    let itemID: String
    let entries: [LeoPluginActionEntry]
}

/// What a List draws and how it reacts to keys. AppKit-free so the
/// interaction rules (Return, ⌘↩, context menu, selection across diffs) are
/// unit-tested; `LeoPluginListView` is a thin shell over it.
@MainActor
final class LeoPluginListModel {
    enum Row: Equatable {
        case header(key: String, title: String)
        case item(LeoPluginNode.Item)

        var key: String {
            switch self {
            case .header(let key, _): "h:\(key)"
            case .item(let item): "i:\(item.id)"
            }
        }

        var itemID: String? {
            if case .item(let item) = self { item.id } else { nil }
        }
    }

    private(set) var list: LeoPluginNode.List
    private(set) var rows: [Row]
    private(set) var selectedItemID: String?
    private(set) var actionPanel: LeoPluginActionPanelState?
    private let emitter: LeoPluginActionEmitter

    init(list: LeoPluginNode.List, mint: LeoPluginGestureMint, handler: @escaping LeoPluginActionHandler) {
        self.list = list
        self.rows = Self.rows(for: list)
        self.emitter = LeoPluginActionEmitter(mint: mint, handler: handler)
    }

    // MARK: Queries

    func rowIndex(forKey key: String) -> Int? { rows.firstIndex { $0.key == key } }

    func item(withID id: String) -> LeoPluginNode.Item? {
        rows.lazy.compactMap { row -> LeoPluginNode.Item? in
            if case .item(let item) = row, item.id == id { item } else { nil }
        }.first
    }

    /// The context menu is exactly the item's actions, in order.
    func contextMenu(forItem id: String) -> [LeoPluginActionEntry] {
        LeoPluginActionPresentation.entries(for: item(withID: id)?.actions ?? [])
    }

    // MARK: Selection

    func select(itemID: String?) {
        guard let itemID else { selectedItemID = nil; return }
        guard item(withID: itemID) != nil else { return }
        selectedItemID = itemID
    }

    /// Moves to the next item row, skipping headers. Stops at either end.
    func moveSelection(by delta: Int) {
        let itemRows = rows.compactMap(\.itemID)
        guard !itemRows.isEmpty else { return }
        let current = selectedItemID.flatMap { itemRows.firstIndex(of: $0) }
        let target = (current ?? (delta > 0 ? -1 : itemRows.count)) + delta
        selectedItemID = itemRows[min(max(target, 0), itemRows.count - 1)]
    }

    // MARK: Keys and actions

    /// Returns whether the key was consumed.
    @discardableResult
    func handleKey(_ key: LeoPluginListKey) -> Bool {
        guard let id = selectedItemID, let item = item(withID: id), !item.actions.isEmpty else { return false }
        switch key {
        case .return:
            emitter.emit(item.actions[0], origin: .keyboard)
        case .commandReturn:
            actionPanel = LeoPluginActionPanelState(
                itemID: id, entries: LeoPluginActionPresentation.entries(for: item.actions))
        }
        return true
    }

    func closeActionPanel() { actionPanel = nil }

    func performPanelEntry(at index: Int, origin: LeoPluginGesture.Origin) {
        guard let panel = actionPanel, panel.entries.indices.contains(index) else { return }
        actionPanel = nil
        emitter.emit(panel.entries[index].action, origin: origin)
    }

    func performContextMenuEntry(item id: String, at index: Int) {
        let entries = contextMenu(forItem: id)
        guard entries.indices.contains(index) else { return }
        emitter.emit(entries[index].action, origin: .click)
    }

    /// A click on the row's primary affordance (double-click) runs the first action.
    func performPrimary(item id: String, origin: LeoPluginGesture.Origin) {
        guard let first = item(withID: id)?.actions.first else { return }
        emitter.emit(first, origin: origin)
    }

    // MARK: Updates

    /// Adopts a new list and reports the row edits. Selection stays on the
    /// same item id; if that item vanished, the nearest surviving item is
    /// selected.
    @discardableResult
    func apply(list newList: LeoPluginNode.List) -> LeoPluginRowChange {
        let oldRows = rows
        let newRows = Self.rows(for: newList)
        let change = Self.change(from: oldRows, to: newRows)
        let previousSelection = selectedItemID
        list = newList
        rows = newRows
        selectedItemID = Self.survivingSelection(previous: previousSelection, oldRows: oldRows, newRows: newRows)
        reconcilePanel()
        return change
    }

    private func reconcilePanel() {
        guard let panel = actionPanel else { return }
        guard let item = item(withID: panel.itemID), !item.actions.isEmpty else { actionPanel = nil; return }
        actionPanel = LeoPluginActionPanelState(
            itemID: panel.itemID, entries: LeoPluginActionPresentation.entries(for: item.actions))
    }

    // MARK: Pure helpers

    static func rows(for list: LeoPluginNode.List) -> [Row] {
        list.sections.enumerated().flatMap { index, section -> [Row] in
            let header: [Row] = section.title.map { [.header(key: section.id ?? "#\(index)", title: $0)] } ?? []
            return header + section.items.map(Row.item)
        }
    }

    static func change(from old: [Row], to new: [Row]) -> LeoPluginRowChange {
        let oldKeys = old.map(\.key)
        let newKeys = new.map(\.key)
        var change = LeoPluginRowChange()
        for step in newKeys.difference(from: oldKeys) {
            switch step {
            case .remove(let offset, _, _): change.removed.insert(offset)
            case .insert(let offset, _, _): change.inserted.insert(offset)
            }
        }
        let oldByKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, row) in new.enumerated() where !change.inserted.contains(index) {
            if let previous = oldByKey[row.key], previous != row { change.updated.insert(index) }
        }
        return change
    }

    private static func survivingSelection(previous: String?, oldRows: [Row], newRows: [Row]) -> String? {
        guard let previous else { return nil }
        let newItems = newRows.compactMap(\.itemID)
        if newItems.contains(previous) { return previous }
        // Walk forward from where the item was, then backward, for a neighbour that survived.
        guard let oldIndex = oldRows.firstIndex(where: { $0.itemID == previous }) else { return newItems.first }
        let survivors = Set(newItems)
        let after = oldRows[(oldIndex + 1)...].compactMap(\.itemID).first(where: survivors.contains)
        let before = oldRows[..<oldIndex].reversed().compactMap(\.itemID).first(where: survivors.contains)
        return after ?? before
    }
}
