import Foundation

/// An open edit of a list of names (the hide list): the list as it was read
/// and the one typed. What the edit means is the set of names it added and
/// removed against that base, so it can be replayed over a newer list without
/// undoing another writer's additions or removals.
public struct LeoDelegationListEdit: Equatable, Sendable {
    public private(set) var base: [String]
    public var names: [String]

    public init(base: [String]) {
        self.base = base
        names = base
    }

    private init(base: [String], names: [String]) {
        self.base = base
        self.names = names
    }

    public var added: [String] { names.filter { !base.contains($0) } }
    public var removed: [String] { base.filter { !names.contains($0) } }
    public var isDirty: Bool { names != base }

    /// `fresh` with the edit's removals taken out and its additions put on the
    /// end. Over a list that is still the base, exactly what was typed (order included).
    public func applied(to fresh: [String]) -> [String] {
        guard fresh != base else { return names }
        let removed = Set(removed)
        let kept = fresh.filter { !removed.contains($0) }
        return kept + added.filter { !kept.contains($0) }
    }

    /// The same edit against a newer read.
    public func rebased(onto fresh: [String]) -> LeoDelegationListEdit {
        LeoDelegationListEdit(base: fresh, names: applied(to: fresh))
    }
}
