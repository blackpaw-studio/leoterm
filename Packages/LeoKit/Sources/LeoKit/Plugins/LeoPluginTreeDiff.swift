import Foundation

public enum LeoPluginItemEdit: Equatable, Sendable {
    case delete(id: String)
    case insert(id: String, index: Int, item: LeoPluginNode.Item)
    case move(id: String, index: Int)
    case update(id: String, item: LeoPluginNode.Item)
}

public enum LeoPluginSectionEdit: Equatable, Sendable {
    case delete(key: String)
    case insert(key: String, index: Int, section: LeoPluginNode.Section)
    case move(key: String, index: Int)
}

/// Header and item changes for a section present in both trees.
public struct LeoPluginSectionPatch: Equatable, Sendable {
    public var key: String
    public var retitled: Bool
    public var title: String?
    public var itemEdits: [LeoPluginItemEdit]
}

public struct LeoPluginListPatch: Equatable, Sendable {
    /// Structural section edits, applied in order (deletes, then inserts/moves by target index).
    public var sectionEdits: [LeoPluginSectionEdit]
    /// Per-section patches, keyed by section key, applied after `sectionEdits`.
    public var sections: [LeoPluginSectionPatch]
}

public enum LeoPluginTreeOp: Equatable, Sendable {
    case replaceRoot([LeoPluginNode])
    case replaceNode(index: Int, node: LeoPluginNode)
    case updateList(index: Int, patch: LeoPluginListPatch)
}

/// Keyed diff of slot roots, so the renderer can keep selection and scroll and update rows in place.
/// Items are keyed by id; sections by id, or by position when they have none.
public enum LeoPluginTreeDiff {
    public static func diff(old: [LeoPluginNode], new: [LeoPluginNode]) -> [LeoPluginTreeOp] {
        guard old.count == new.count, zip(old, new).allSatisfy({ sameKind($0, $1) }) else {
            return [.replaceRoot(new)]
        }
        return zip(old, new).enumerated().compactMap { index, pair in
            let (o, n) = pair
            guard o != n else { return nil }
            if case .list(let ol) = o, case .list(let nl) = n, let patch = listPatch(old: ol, new: nl) {
                return .updateList(index: index, patch: patch)
            }
            return .replaceNode(index: index, node: n)
        }
    }

    public static func itemEdits(old: [LeoPluginNode.Item], new: [LeoPluginNode.Item]) -> [LeoPluginItemEdit] {
        keyedEdits(old: old, new: new, key: \.id, isEqual: ==).map {
            switch $0 {
            case .delete(let k): .delete(id: k)
            case .insert(let k, let i, let v): .insert(id: k, index: i, item: v)
            case .move(let k, let i): .move(id: k, index: i)
            case .update(let k, let v): .update(id: k, item: v)
            }
        }
    }

    public static func apply(_ edits: [LeoPluginItemEdit], to items: [LeoPluginNode.Item]) -> [LeoPluginNode.Item] {
        applyKeyed(edits.map {
            switch $0 {
            case .delete(let id): .delete(id)
            case .insert(let id, let i, let v): .insert(id, i, v)
            case .move(let id, let i): .move(id, i)
            case .update(let id, let v): .update(id, v)
            }
        }, to: items, keys: items.map(\.id))
    }

    public static func apply(_ patch: LeoPluginListPatch, to list: LeoPluginNode.List) -> LeoPluginNode.List {
        let sections = applyKeyed(patch.sectionEdits.map {
            switch $0 {
            case .delete(let k): KeyedEdit<LeoPluginNode.Section>.delete(k)
            case .insert(let k, let i, let v): .insert(k, i, v)
            case .move(let k, let i): .move(k, i)
            }
        }, to: list.sections, keys: keys(list.sections))
        let patched = sections.enumerated().map { offset, section -> LeoPluginNode.Section in
            var section = section
            let key = section.id ?? "#\(offset)"
            guard let p = patch.sections.first(where: { $0.key == key }) else { return section }
            if p.retitled { section.title = p.title }
            section.items = apply(p.itemEdits, to: section.items)
            return section
        }
        return .init(sections: patched)
    }

    // MARK: Lists

    private static func listPatch(old: LeoPluginNode.List, new: LeoPluginNode.List) -> LeoPluginListPatch? {
        let oldKeys = keys(old.sections), newKeys = keys(new.sections)
        let allItems = { (l: LeoPluginNode.List) in l.sections.flatMap(\.items).map(\.id) }
        guard Set(oldKeys).count == oldKeys.count, Set(newKeys).count == newKeys.count,
              Set(allItems(old)).count == allItems(old).count, Set(allItems(new)).count == allItems(new).count
        else { return nil }

        let oldByKey = Dictionary(uniqueKeysWithValues: zip(oldKeys, old.sections))
        let structural: [LeoPluginSectionEdit] = keyedEdits(
            old: Array(zip(oldKeys, old.sections)), new: Array(zip(newKeys, new.sections)), key: \.0,
            isEqual: { _, _ in true }  // section contents are patched separately
        ).compactMap {
            switch $0 {
            case .delete(let k): .delete(key: k)
            case .insert(let k, let i, let v): .insert(key: k, index: i, section: v.1)
            case .move(let k, let i): .move(key: k, index: i)
            case .update: nil
            }
        }
        let patches = zip(newKeys, new.sections).compactMap { key, section -> LeoPluginSectionPatch? in
            guard let before = oldByKey[key] else { return nil }
            let retitled = before.title != section.title
            let edits = itemEdits(old: before.items, new: section.items)
            guard retitled || !edits.isEmpty else { return nil }
            return .init(key: key, retitled: retitled, title: section.title, itemEdits: edits)
        }
        return .init(sectionEdits: structural, sections: patches)
    }

    private static func keys(_ sections: [LeoPluginNode.Section]) -> [String] {
        sections.enumerated().map { $1.id ?? "#\($0)" }
    }

    private static func sameKind(_ a: LeoPluginNode, _ b: LeoPluginNode) -> Bool {
        switch (a, b) {
        case (.list, .list), (.detail, .detail), (.form, .form), (.accessory, .accessory),
             (.text, .text), (.meter, .meter), (.emptyState, .emptyState), (.loading, .loading), (.error, .error): true
        default: false
        }
    }

    // MARK: Generic keyed diff

    fileprivate enum KeyedEdit<Value> {
        case delete(String)
        case insert(String, Int, Value)
        case move(String, Int)
        case update(String, Value)
    }

    /// Deletes first, then walks `new` in order: insert what is missing, move what is out of place,
    /// update what changed. Applying the result to `old` yields `new`.
    private static func keyedEdits<T>(
        old: [T], new: [T], key: (T) -> String, isEqual: (T, T) -> Bool
    ) -> [KeyedEdit<T>] {
        let newKeys = Set(new.map(key))
        var edits: [KeyedEdit<T>] = old.map(key).filter { !newKeys.contains($0) }.map { .delete($0) }
        var working = old.filter { newKeys.contains(key($0)) }
        for (i, value) in new.enumerated() {
            let k = key(value)
            if let at = working.firstIndex(where: { key($0) == k }) {
                if at != i {
                    let moved = working.remove(at: at)
                    working.insert(moved, at: i)
                    edits.append(.move(k, i))
                }
                if !isEqual(working[i], value) {
                    working[i] = value
                    edits.append(.update(k, value))
                }
            } else {
                working.insert(value, at: i)
                edits.append(.insert(k, i, value))
            }
        }
        return edits
    }

    private static func applyKeyed<T>(
        _ edits: [KeyedEdit<T>], to values: [T], keys: [String]
    ) -> [T] {
        var entries: [(String, T)] = Array(zip(keys, values))
        for edit in edits {
            switch edit {
            case .delete(let k): entries.removeAll { $0.0 == k }
            case .insert(let k, let i, let v): entries.insert((k, v), at: min(i, entries.count))
            case .move(let k, let i):
                if let at = entries.firstIndex(where: { $0.0 == k }) {
                    let e = entries.remove(at: at)
                    entries.insert(e, at: min(i, entries.count))
                }
            case .update(let k, let v):
                if let at = entries.firstIndex(where: { $0.0 == k }) { entries[at].1 = v }
            }
        }
        return entries.map(\.1)
    }
}
