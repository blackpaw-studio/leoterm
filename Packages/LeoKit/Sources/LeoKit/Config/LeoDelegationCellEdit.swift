import Foundation

/// An open edit of one cell: the cell as it was read (`base`) and what the
/// user has typed (`target`). A cell write replaces the whole cell, so the
/// edit sends only what the user changed laid over the cell as it is now, and
/// never resends a stale key it didn't touch.
public struct LeoDelegationCellEdit: Equatable, Sendable {
    public enum Key: Sendable { case template, model, effort }

    public private(set) var base: LeoDelegationTarget
    public var target: LeoDelegationTarget

    /// `base` is nil for a profile that doesn't route the role yet.
    public init(base: LeoDelegationTarget?) {
        let start = base ?? LeoDelegationTarget()
        self.base = start
        target = start
    }

    private init(base: LeoDelegationTarget, target: LeoDelegationTarget) {
        self.base = base
        self.target = target
    }

    public var changedKeys: Set<Key> {
        var keys: Set<Key> = []
        if target.template != base.template { keys.insert(.template) }
        if target.model != base.model { keys.insert(.model) }
        if target.effort != base.effort { keys.insert(.effort) }
        return keys
    }

    public var isDirty: Bool { !changedKeys.isEmpty }

    /// An empty template deletes the cell.
    public var deletesCell: Bool { target.template.isEmpty }

    /// `fresh` (the cell now, nil if it has none) with the edited keys over it; the typed cell as it is when there is none.
    public func merged(onto fresh: LeoDelegationTarget?) -> LeoDelegationTarget {
        // A cell another writer deleted: only the whole typed cell keeps the
        // edit, since an empty template sent in its place would delete nothing.
        guard var result = fresh else { return target }
        for key in changedKeys {
            switch key {
            case .template: result.template = target.template
            case .model: result.model = target.model
            case .effort: result.effort = target.effort
            }
        }
        return result
    }

    /// The same edit against a newer read: the edited keys stay, the others
    /// follow `fresh`. A cell that is gone keeps everything typed, against an empty base.
    public func rebased(onto fresh: LeoDelegationTarget?) -> LeoDelegationCellEdit {
        guard let fresh else { return LeoDelegationCellEdit(base: LeoDelegationTarget(), target: target) }
        return LeoDelegationCellEdit(base: fresh, target: merged(onto: fresh))
    }

    public mutating func revert() {
        target = base
    }
}
