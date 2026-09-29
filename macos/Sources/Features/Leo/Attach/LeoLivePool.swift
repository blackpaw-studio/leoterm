import Foundation

/// D-108: how many tmux clients (live agent surfaces) a window keeps
/// attached, counting what it shows and what it holds hidden.
enum LeoLivePoolCapacity {
    static let perWindow = 4
}

/// B-056 (D-098): what a window keeps attached but hidden, so switching
/// back to a recently viewed row is instant and keeps Ghostty's
/// scrollback, scroll position and selection. Pure and immutable: each
/// change returns a new pool, plus whatever fell out of it for the caller
/// to let go.
///
/// Entries run least -> most recently viewed; the content on screen is not
/// in the pool. Capacity counts tmux clients -- the shown content's plus
/// every hidden entry's -- so a split holding two agents weighs two.
struct LeoLivePool<Entry> {
    let capacity: Int
    let entries: [Entry]

    init(capacity: Int = LeoLivePoolCapacity.perWindow, entries: [Entry] = []) {
        self.capacity = capacity
        self.entries = entries
    }

    /// `entry` hidden as the most recently viewed.
    func hiding(_ entry: Entry) -> Self {
        Self(capacity: capacity, entries: entries + [entry])
    }

    /// The most recently viewed entry matching `predicate`, taken out (to
    /// be shown again).
    func taking(where predicate: (Entry) -> Bool) -> (pool: Self, taken: Entry?) {
        guard let index = entries.lastIndex(where: predicate) else { return (self, nil) }
        var remaining = entries
        let taken = remaining.remove(at: index)
        return (Self(capacity: capacity, entries: remaining), taken)
    }

    /// Every entry matching `predicate`, taken out (to be let go).
    func removing(where predicate: (Entry) -> Bool) -> (pool: Self, removed: [Entry]) {
        (Self(capacity: capacity, entries: entries.filter { !predicate($0) }), entries.filter(predicate))
    }

    /// Entries with no live client are dropped (nothing left worth
    /// keeping), then the least recently viewed go until the shown
    /// content's `shownClients` plus the hidden entries' fit `capacity`.
    func trimmed(shownClients: Int, clients: (Entry) -> Int) -> (pool: Self, evicted: [Entry]) {
        let weighed = entries.map { (entry: $0, clients: clients($0)) }
        let (live, dead) = (weighed.filter { $0.clients > 0 }, weighed.filter { $0.clients <= 0 })
        let budget = capacity - shownClients
        let dropCount = Self.leastRecentToDrop(live.map(\.clients), budget: budget)
        return (
            Self(capacity: capacity, entries: live.dropFirst(dropCount).map(\.entry)),
            dead.map(\.entry) + live.prefix(dropCount).map(\.entry)
        )
    }

    /// How many of `weights` (least recent first) must go for the rest to
    /// fit `budget`.
    private static func leastRecentToDrop(_ weights: [Int], budget: Int) -> Int {
        var total = weights.reduce(0, +)
        var dropped = 0
        while total > budget, dropped < weights.count {
            total -= weights[dropped]
            dropped += 1
        }
        return dropped
    }
}
