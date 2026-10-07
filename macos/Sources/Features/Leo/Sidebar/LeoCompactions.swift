import Foundation

/// What a row shows of a running compaction (B-261): only that one is in
/// progress, and who asked for it. Fixed copy is drawn from this; no
/// daemon text ever reaches the row.
struct LeoRowCompaction: Equatable, Sendable {
    let trigger: LeoCompactionTrigger?
}

/// The agents compacting right now. `/state` carries no compaction, so the
/// `agent_compaction` events are the only source: `started` records an
/// entry stamped with the `started_at` of the row it arrived for, and
/// attaches only to a row of that same incarnation (D-074); the end event
/// (or any reset) removes it. Values only; the feed owns the one instance.
struct LeoCompactions: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let startedAt: String
        let compaction: LeoRowCompaction
    }

    private let entries: [String: Entry]
    /// The daemon boot these were recorded under; another boot clears them.
    private let bootID: String?

    static let empty = LeoCompactions(entries: [:], bootID: nil)

    func recording(_ event: LeoCompactionEvent, startedAt: String) -> LeoCompactions {
        var next = entries
        next[event.agent] = Entry(startedAt: startedAt, compaction: LeoRowCompaction(trigger: event.trigger))
        return LeoCompactions(entries: next, bootID: bootID)
    }

    func ending(_ name: String) -> LeoCompactions {
        guard entries[name] != nil else { return self }
        return LeoCompactions(entries: entries.filter { $0.key != name }, bootID: bootID)
    }

    /// Everything recorded under another daemon boot is dropped; the first
    /// boot seen (or none advertised) keeps what's there.
    func observingBoot(_ boot: String?) -> LeoCompactions {
        guard let boot else { return self }
        return LeoCompactions(entries: boot == bootID || bootID == nil ? entries : [:], bootID: boot)
    }

    func compaction(name: String, startedAt: String?) -> LeoRowCompaction? {
        guard let startedAt, let entry = entries[name], entry.startedAt == startedAt else { return nil }
        return entry.compaction
    }

    func attach(to rows: [LeoAgentRow]) -> [LeoAgentRow] {
        rows.map { $0.withCompaction(compaction(name: $0.name, startedAt: $0.startedAt)) }
    }
}
