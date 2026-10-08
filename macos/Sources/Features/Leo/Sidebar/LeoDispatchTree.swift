import Foundation

/// One dispatch placed under an agent row: `depth` 0 is a direct child of
/// the row, 1 a dispatch of that dispatch, and so on.
struct LeoDispatchNode: Equatable, Sendable, Identifiable {
    let dispatch: LeoDispatch
    let depth: Int

    var id: String { dispatch.id }
}

/// The selected host's live dispatches, nested for the sidebar (B-257).
/// Pure value: the `/state` baseline reconciles it, `dispatch_changed`
/// upserts into it, and a terminal status or `ended_at` removes a record
/// at once (no lingering). Ids that ended live are remembered for the
/// daemon's lifetime (capped), so a baseline taken before the end can't
/// bring them back. Nothing shows unless the daemon advertised
/// `dispatch_tree`: no source means no rows, never an invented state.
struct LeoDispatchTree: Equatable, Sendable {
    /// How many ended ids are remembered; the oldest falls out first.
    static let endedCap = 256
    /// How many live records are kept; a new id past it is ignored (a
    /// daemon never runs this many, so it only bounds a broken one).
    static let recordCap = 1024
    /// Nesting deeper than this is not shown.
    static let maxDepth = 16

    private(set) var isEnabled = false
    private var records: [String: LeoDispatch] = [:]
    private var endedIDs: [String] = []
    private var endedSet: Set<String> = []
    private var bootID: String?
    /// Bumped by every live upsert; `upsertMarks` holds each record's.
    private(set) var mark = 0
    private var upsertMarks: [String: Int] = [:]
    /// `state_seq`: the daemon event seq each record last reflects (a live
    /// event's, or the baseline's `meta.seq`), and the newest baseline seq
    /// applied.
    private var recordSeqs: [String: Int] = [:]
    private var baselineSeq: Int?

    /// Returns whether it changed.
    @discardableResult
    mutating func setEnabled(_ enabled: Bool) -> Bool {
        defer { isEnabled = enabled }
        return isEnabled != enabled
    }

    /// Replaces every record with `dispatches`' live ones, minus any id
    /// that already ended. `mark` is `self.mark` read when the fetch
    /// started: a record the daemon reported live after it is newer than
    /// the baseline, so it stays as it is. A record the fetch began after
    /// the last report of is confirmed stale and goes if the baseline
    /// omits it. A dropped connection never calls this: the last-known
    /// records stay until the reconnect's baseline reconciles them.
    /// Returns whether the records changed.
    @discardableResult
    mutating func applyBaseline(_ dispatches: [LeoDispatch], since mark: Int? = nil, atSeq seq: Int? = nil) -> Bool {
        let previous = records
        var updated = Dictionary(
            dispatches.filter { $0.isLive && !endedSet.contains($0.id) }.prefix(Self.recordCap).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var kept: Set<String> = []
        if usesStateSeq, let seq {
            // The snapshot reflects every event up to `seq` (and maybe
            // later ones): a record whose last event is newer stays.
            if let baselineSeq, seq < baselineSeq { return false }
            for (id, record) in records where (recordSeqs[id] ?? 0) > seq {
                updated[id] = record
                kept.insert(id)
            }
            baselineSeq = seq
        } else if let mark {
            for (id, record) in records where (upsertMarks[id] ?? 0) > mark {
                updated[id] = record
                kept.insert(id)
            }
        }
        records = updated
        upsertMarks = upsertMarks.filter { updated[$0.key] != nil }
        if usesStateSeq, let seq {
            recordSeqs = updated.keys.reduce(into: [:]) { $0[$1] = kept.contains($1) ? recordSeqs[$1] : seq }
        } else {
            recordSeqs = recordSeqs.filter { updated[$0.key] != nil }
        }
        return records != previous
    }

    private(set) var usesStateSeq = false

    /// Whether `/state`'s `meta.seq` orders baselines (`state_seq`).
    mutating func setStateSeq(_ enabled: Bool) { usesStateSeq = enabled }

    /// Applies one live record. Returns whether the records changed.
    @discardableResult
    mutating func upsert(_ dispatch: LeoDispatch, seq: Int? = nil) -> Bool {
        guard !endedSet.contains(dispatch.id) else { return false }
        guard dispatch.isLive else {
            rememberEnded(dispatch.id)
            upsertMarks[dispatch.id] = nil
            recordSeqs[dispatch.id] = nil
            return records.removeValue(forKey: dispatch.id) != nil
        }
        guard records[dispatch.id] != nil || records.count < Self.recordCap else { return false }
        if usesStateSeq, let seq, isReflectedInState(dispatch.id, bySeq: seq) { return false }
        // Every live report counts, changed or not: an identical republish
        // that lands while a `/state` fetch is in flight proves the record
        // is live after that fetch began, so a baseline omitting it is the
        // stale one.
        mark += 1
        upsertMarks[dispatch.id] = mark
        if usesStateSeq, let seq { recordSeqs[dispatch.id] = seq }
        guard records[dispatch.id] != dispatch else { return false }
        records[dispatch.id] = dispatch
        return true
    }

    /// Whether an event at `seq` is already in what the record (or, for an
    /// unknown record, the last baseline) reflects.
    private func isReflectedInState(_ id: String, bySeq seq: Int) -> Bool {
        if let recorded = recordSeqs[id] { return seq <= recorded }
        guard records[id] == nil, let baselineSeq else { return false }
        return seq <= baselineSeq
    }

    /// Notes the daemon's boot id. A different daemon restarts its ids'
    /// meaning, so the ended ids are forgotten. Returns whether it changed
    /// (the first boot seen is not a change).
    @discardableResult
    mutating func observeBoot(_ id: String?) -> Bool {
        guard let id else { return false }
        defer { bootID = id }
        guard let bootID, bootID != id else { return false }
        records = [:]
        upsertMarks = [:]
        recordSeqs = [:]
        baselineSeq = nil
        endedIDs = []
        endedSet = []
        return true
    }

    /// Forgets everything (host switch, stop).
    mutating func reset() { self = LeoDispatchTree() }

    /// The dispatches under `agent`'s row, depth first. A root is a
    /// dispatch with no parent, or whose parent is no longer live; it sits
    /// under the row its `caller_agent` names (so an orphan whose caller
    /// has no row shows nowhere).
    func children(of agent: String) -> [LeoDispatchNode] {
        guard isEnabled else { return [] }
        let roots = sorted(records.values.filter { isRoot($0) && $0.callerAgent == agent })
        var nodes: [LeoDispatchNode] = []
        var visited: Set<String> = []
        for root in roots { appendSubtree(root, depth: 0, into: &nodes, visited: &visited) }
        return nodes
    }

    /// `children(of:)` for each of `agents`, leaving out the empty ones.
    func projection(for agents: [String]) -> [String: [LeoDispatchNode]] {
        guard isEnabled, !records.isEmpty else { return [:] }
        return agents.reduce(into: [:]) { result, agent in
            let nodes = children(of: agent)
            if !nodes.isEmpty { result[agent] = nodes }
        }
    }

    private func isRoot(_ dispatch: LeoDispatch) -> Bool {
        guard let parent = dispatch.parentDispatchID else { return true }
        return records[parent] == nil
    }

    private func appendSubtree(_ dispatch: LeoDispatch, depth: Int, into nodes: inout [LeoDispatchNode], visited: inout Set<String>) {
        guard depth <= Self.maxDepth, visited.insert(dispatch.id).inserted else { return }
        nodes.append(LeoDispatchNode(dispatch: dispatch, depth: depth))
        let kids = sorted(records.values.filter { $0.parentDispatchID == dispatch.id })
        for kid in kids { appendSubtree(kid, depth: depth + 1, into: &nodes, visited: &visited) }
    }

    /// Oldest first, then by id, so siblings keep a stable order.
    private func sorted(_ dispatches: [LeoDispatch]) -> [LeoDispatch] {
        dispatches.sorted { ($0.startedAt ?? "", $0.id) < ($1.startedAt ?? "", $1.id) }
    }

    private mutating func rememberEnded(_ id: String) {
        guard endedSet.insert(id).inserted else { return }
        endedIDs.append(id)
        guard endedIDs.count > Self.endedCap else { return }
        endedSet.remove(endedIDs.removeFirst())
    }
}
