/// B-438: the order of the sidebar's top-level sections, as keys: every
/// machine together as `agents` (they keep their Settings order inside
/// it), this window's `terminals`, and each plugin section as
/// `pluginKey(_:)`.
///
/// The saved order is never pruned to what shows: a section that is
/// hidden, turned off or uninstalled keeps its slot and comes back to it.
/// A section the order doesn't name yet (a plugin installed since) goes at
/// the bottom. Moves work on the sections that show (`visible`, top to
/// bottom) and are merged back so the others keep their slots.
enum LeoSidebarSectionOrder {
    static let agents = "agents"
    static let terminals = "terminals"
    /// The default order, before any plugin sections.
    static let builtIns = [agents, terminals]

    static func pluginKey(_ entryID: String) -> String { "plugin:\(entryID)" }

    enum Direction { case up, down }

    /// `live` in the saved order: the saved keys that are live, as saved,
    /// then the live keys not saved yet, in their own order.
    static func arrange(saved: [String], live: [String]) -> [String] {
        let liveKeys = Set(live)
        let kept = unique(saved).filter(liveKeys.contains)
        let keptKeys = Set(kept)
        return kept + unique(live).filter { !keptKeys.contains($0) }
    }

    static func canMove(_ key: String, _ direction: Direction, visible: [String]) -> Bool {
        neighbour(of: key, direction, in: visible) != nil
    }

    /// The full order with `key` swapped with the shown section above or
    /// below it; nil when it can't move that way.
    static func moving(_ key: String, _ direction: Direction, visible: [String], saved: [String], known: [String]) -> [String]? {
        guard let index = visible.firstIndex(of: key), let other = neighbour(of: key, direction, in: visible) else { return nil }
        var reordered = visible
        reordered.swapAt(index, other)
        return merging(reordered, into: saved, known: known + visible)
    }

    /// The full order with `key` dropped on `target`'s header: it takes
    /// that slot, so it lands after a header below it and before one
    /// above. Nil when either isn't shown, or they're the same.
    static func moving(_ key: String, onto target: String, visible: [String], saved: [String], known: [String]) -> [String]? {
        guard key != target, let from = visible.firstIndex(of: key), let to = visible.firstIndex(of: target) else { return nil }
        var reordered = visible
        reordered.remove(at: from)
        reordered.insert(key, at: to)
        return merging(reordered, into: saved, known: known + visible)
    }

    private static func neighbour(of key: String, _ direction: Direction, in visible: [String]) -> Int? {
        guard let index = visible.firstIndex(of: key) else { return nil }
        let other = direction == .up ? index - 1 : index + 1
        return visible.indices.contains(other) ? other : nil
    }

    /// Every known section in the saved order, with the slots the shown
    /// ones hold refilled by `reordered`.
    private static func merging(_ reordered: [String], into saved: [String], known: [String]) -> [String] {
        let full = arrange(saved: saved, live: known)
        let shown = Set(reordered)
        var next = reordered.makeIterator()
        return full.map { shown.contains($0) ? next.next() ?? $0 : $0 }
    }

    private static func unique(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }
}
