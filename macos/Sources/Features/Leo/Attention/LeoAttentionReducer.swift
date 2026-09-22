import Foundation

/// Pure attention state machine for the agents of one host (the selected
/// one): folds daemon attention signals, `/state` baselines, host switches,
/// disconnects, focus changes and clock ticks into committed per-agent
/// states, Dock acknowledgements and live transitions. No AppKit, network
/// or wall clock -- `now` is whatever monotonic time the owner
/// (`LeoSidebarFeed`) passes in, so tests script it directly.
///
/// Rules (see docs/superpowers/specs/2026-09-21-leo-attention-model.md):
/// - A live signal commits only after `stabilityInterval` without a
///   different candidate; a same-state repeat does not extend the window.
/// - A newer-revision repeat of needs_input/finished/errored is a new event.
/// - A changed `hello.boot_id` (daemon restart) discards stored revisions.
/// - Signals at or below an agent's last-seen revision are ignored.
/// - Baselines (and events buffered while recovering) commit silently.
/// - Disconnect marks everything stale until the next baseline.
/// - Focusing an agent acknowledges its Dock contribution; the badge stays.
struct LeoAttentionReducer: Equatable, Sendable {
    static let stabilityInterval: TimeInterval = 0.3

    private struct Candidate: Equatable, Sendable {
        var signal: LeoAttentionSignal
        let since: TimeInterval
    }

    private struct Entry: Equatable, Sendable {
        var committed: LeoAttentionSignal?
        var candidate: Candidate?
        var lastSeenRevision: Int
        var acknowledgedRevision: Int?
        var isStale = false

        var deadline: TimeInterval? { candidate.map { $0.since + LeoAttentionReducer.stabilityInterval } }
    }

    private(set) var host: LeoHostID = .local
    private var entries: [String: Entry] = [:]
    /// Live signals received while waiting for a baseline; merged into it
    /// by revision, silently.
    private var buffered: [String: LeoAttentionSignal] = [:]
    /// True until the first baseline for the current host, and again from
    /// any recovery/disconnect until the next one.
    private var isRecovering = true
    /// The focused attachment on any host. Kept across host switches: focus
    /// is only reported when it changes, so switching away and back must
    /// not forget it.
    private var focusedID: LeoAgentRow.ID?
    /// The last `hello.boot_id` seen for `host`.
    private var bootID: String?
    /// Monotonic for the reducer's whole life (kept across host switches):
    /// each `resetAgent` takes the next value as that agent's incarnation,
    /// so `(bootID, incarnation, revision)` never repeats for one agent.
    private var incarnationCounter = 0
    /// Agents reset, recreated or dropped from the list since the last host
    /// switch or daemon restart; others are incarnation 0. A dropped agent
    /// keeps its entry as a tombstone, so one recreated under the same name
    /// never reuses the incarnation its notifications were posted under.
    private var incarnations: [String: Int] = [:]
    /// Names given a tombstone incarnation by `tombstone(_:)` and not heard
    /// from since. Only these are trimmed, the oldest first, to
    /// `tombstoneLimit`: a live agent reset by `resetAgent` keeps its
    /// incarnation however long it stays quiet.
    private var tombstoned: Set<String> = []
    /// The revision floor of each listed agent a recovery baseline lacked,
    /// dropped with its state. The agent's next signal below it means its
    /// revisions started over (it was recreated), so that signal starts a
    /// new incarnation; at or above it, the incarnation carries on and a
    /// re-sent revision dedupes against what was already posted.
    private var droppedFloors: [String: Int] = [:]

    /// The focused agent's name, only when it belongs to `host`.
    private var focusedAgent: String? { focusedID.flatMap { $0.host == host ? $0.name : nil } }

    /// The earliest moment a pending candidate can commit, if any.
    var nextDeadline: TimeInterval? { entries.values.compactMap(\.deadline).min() }

    // MARK: Connection lifecycle

    /// Clears every state, candidate and acknowledgement; the new host is
    /// silent until its first baseline. Focus and the incarnation counter
    /// carry over.
    mutating func switchHost(_ host: LeoHostID) {
        var next = LeoAttentionReducer()
        next.host = host
        next.focusedID = focusedID
        next.incarnationCounter = incarnationCounter
        self = next
    }

    /// Records the daemon's `hello.boot_id`. A different id than the last
    /// one seen for this host means the daemon restarted and revisions
    /// started over: every stored revision, acknowledgement and buffered
    /// signal is discarded and the reducer waits for a silent baseline.
    /// Returns whether that happened. An absent id changes nothing.
    mutating func observeBoot(_ bootID: String?) -> Bool {
        guard let bootID else { return false }
        defer { self.bootID = bootID }
        guard let previous = self.bootID, previous != bootID else { return false }
        entries = [:]
        buffered = [:]
        incarnations = [:]
        tombstoned = []
        droppedFloors = [:]
        isRecovering = true
        return true
    }

    /// hello/reconnect/sequence gap: cancel candidates and buffer live
    /// signals until `applyBaseline`.
    mutating func beginRecovery() {
        entries = entries.mapValues { entry in
            var entry = entry
            entry.candidate = nil
            return entry
        }
        buffered = [:]
        isRecovering = true
    }

    /// Cancels candidates like `beginRecovery` and marks every state stale:
    /// hidden from badges, counts and navigation until the next baseline
    /// replaces them.
    mutating func disconnect() {
        beginRecovery()
        entries = entries.mapValues { entry in
            var entry = entry
            entry.isStale = true
            return entry
        }
    }

    /// Replaces entries with the authoritative `/state` snapshot, merged
    /// with any newer buffered signals. Never produces transitions.
    /// - In recovery the snapshot wins even at a lower revision (a restarted
    ///   daemon starts over), and an agent whose revision went backwards was
    ///   recreated (e.g. while SSE was down), so it starts a new incarnation,
    ///   as `resetAgent` would.
    /// - Outside recovery live signals already applied are at least as new
    ///   as the snapshot, so those entries (and their candidates) stay.
    /// - Deletion is the agent list's call (`retain`), never the snapshot's:
    ///   an agent can be missing from it only because its field isn't set
    ///   yet (a fresh agent) or didn't decode.
    /// - Outside recovery a live (non-stale) entry the snapshot lacks is
    ///   kept; the next signal stays authoritative.
    /// - In recovery such an entry may belong to an agent deleted and
    ///   recreated under the same name, so its state and revision floor are
    ///   dropped (see `droppedFloors`) but its incarnation is kept.
    mutating func applyBaseline(_ baseline: [String: LeoAttentionSignal]) {
        let wasRecovering = isRecovering
        var merged = baseline
        for (agent, signal) in buffered where signal.revision > (merged[agent]?.revision ?? Int.min) {
            merged[agent] = signal
        }
        for (agent, signal) in baseline where wasRecovering && signal.revision < (entries[agent]?.lastSeenRevision ?? Int.min) {
            renew(agent)
        }
        for (agent, signal) in merged where entries[agent] == nil && signal.revision < (droppedFloors[agent] ?? Int.min) {
            renew(agent)
        }
        let kept = entries.filter { agent, entry in
            guard let signal = merged[agent] else { return !wasRecovering && !entry.isStale }
            return !wasRecovering && entry.lastSeenRevision >= signal.revision
        }
        let unconfirmed = entries.filter { kept[$0.key] == nil && merged[$0.key] == nil }
        droppedFloors = droppedFloors.filter { merged[$0.key] == nil }
            .merging(unconfirmed.mapValues(\.lastSeenRevision)) { _, new in new }
        tombstoned.subtract(merged.keys)
        let fresh = merged.filter { kept[$0.key] == nil }.reduce(into: [String: Entry]()) { result, item in
            let previous = entries[item.key]
            let keepsAcknowledgement = previous?.committed == item.value
            result[item.key] = Entry(
                committed: item.value,
                lastSeenRevision: item.value.revision,
                acknowledgedRevision: keepsAcknowledgement ? previous?.acknowledgedRevision : nil
            )
        }
        entries = kept.merging(fresh) { current, _ in current }
        buffered = [:]
        isRecovering = false
        acknowledgeFocused()
    }

    // MARK: Signals and time

    mutating func receive(agent: String, signal: LeoAttentionSignal, now: TimeInterval) {
        tombstoned.remove(agent)
        if isRecovering {
            if signal.revision > (buffered[agent]?.revision ?? Int.min) { buffered[agent] = signal }
            return
        }
        if entries[agent] == nil, let floor = droppedFloors.removeValue(forKey: agent), signal.revision < floor {
            renew(agent)
        }
        var entry = entries[agent] ?? Entry(lastSeenRevision: Int.min)
        guard signal.revision > entry.lastSeenRevision else { return }
        entry.lastSeenRevision = signal.revision
        if entry.candidate?.signal.state == signal.state {
            // Same-state repeat: newest revision, original window.
            entry.candidate?.signal = signal
        } else if entry.committed?.state == signal.state, !signal.state.needsAttention {
            // Flicker back to a committed working/unknown state.
            entry.candidate = nil
        } else {
            // Includes a newer-revision repeat of a committed attention
            // state: a new turn, so it commits (re-arming the Dock count
            // and possibly notifying) like any other transition.
            entry.candidate = Candidate(signal: signal, since: now)
        }
        entries[agent] = entry
    }

    /// Commits every candidate stable since `now - stabilityInterval`, in
    /// agent-name order.
    mutating func tick(now: TimeInterval) -> [LeoAttentionTransition] {
        let due = entries.filter { ($0.value.deadline ?? .infinity) <= now }.keys.sorted()
        return due.compactMap { commit($0) }
    }

    private mutating func commit(_ agent: String) -> LeoAttentionTransition? {
        guard var entry = entries[agent], let candidate = entry.candidate else { return nil }
        let isFocused = focusedAgent == agent
        let signal = candidate.signal
        let from = entry.committed?.state
        entry.committed = signal
        entry.candidate = nil
        if isFocused && signal.state.needsAttention { entry.acknowledgedRevision = signal.revision }
        entries[agent] = entry
        let notifies = !isFocused && (signal.state == .needsInput || signal.state == .finished)
        return LeoAttentionTransition(
            id: LeoAgentRow.ID(host: host, name: agent), from: from, to: signal.state,
            revision: signal.revision, shouldNotify: notifies, bootID: bootID, incarnation: incarnations[agent] ?? 0
        )
    }

    // MARK: Focus and membership

    /// The agent whose attachment is focused (key window -> selected tab ->
    /// focused split), or `nil`. Acknowledges its current attention.
    mutating func focus(_ id: LeoAgentRow.ID?) {
        focusedID = id
        acknowledgeFocused()
    }

    private mutating func acknowledgeFocused() {
        guard let agent = focusedAgent, var entry = entries[agent],
              let committed = entry.committed, committed.state.needsAttention else { return }
        entry.acknowledgedRevision = committed.revision
        entries[agent] = entry
    }

    /// A newly spawned agent may reuse a deleted one's name with revisions
    /// starting over.
    mutating func resetAgent(_ name: String) {
        entries[name] = nil
        buffered[name] = nil
        droppedFloors[name] = nil
        tombstoned.remove(name)
        renew(name)
    }

    /// Starts a new incarnation for `agent`.
    private mutating func renew(_ agent: String) {
        incarnationCounter += 1
        incarnations[agent] = incarnationCounter
    }

    /// Tombstones kept for agents gone from the list (see `incarnations`).
    static let tombstoneLimit = 64

    /// Pass the value read when a list fetch starts to `retain`, so the
    /// list can't drop an agent spawned (reset) after it was fetched.
    var membershipMark: Int { incarnationCounter }

    /// Drops agents no longer in the agent list, leaving each a tombstone
    /// incarnation (see `incarnations`). Agents reset after `mark` are newer
    /// than the list and stay.
    mutating func retain(agents: Set<String>, listedSince mark: Int? = nil) {
        let newer = mark.map { mark in Set(incarnations.filter { $0.value > mark }.keys) } ?? []
        let listed = agents.union(newer).contains
        let dropped = Set(entries.keys).union(buffered.keys).union(droppedFloors.keys).filter { !listed($0) }
        entries = entries.filter { listed($0.key) }
        buffered = buffered.filter { listed($0.key) }
        tombstone(dropped)
    }

    /// Gives each of `agents` a new incarnation and marks it a tombstone,
    /// then trims tombstones to the newest `tombstoneLimit`.
    private mutating func tombstone(_ agents: Set<String>) {
        for agent in agents.sorted() {
            renew(agent)
            droppedFloors[agent] = nil
        }
        tombstoned.formUnion(agents)
        let excess = tombstoned.sorted { incarnations[$0, default: 0] < incarnations[$1, default: 0] }
            .prefix(max(0, tombstoned.count - Self.tombstoneLimit))
        excess.forEach { incarnations[$0] = nil }
        tombstoned.subtract(excess)
    }

    // MARK: Queries

    func state(of agent: String) -> LeoAttentionState? { entries[agent]?.committed?.state }

    /// True until a baseline commits for the current host (buffering live signals).
    var isAwaitingBaseline: Bool { isRecovering }

    /// Whether the daemon has reported semantic attention for `agent`.
    func isSupported(_ agent: String) -> Bool { entries[agent] != nil }

    /// Incarnations kept for agents dropped from the list (tombstones).
    var tombstoneCount: Int { tombstoned.count }

    func isStale(_ agent: String) -> Bool { entries[agent]?.isStale ?? false }

    func needsAttention(_ agent: String) -> Bool {
        guard let entry = entries[agent], !entry.isStale else { return false }
        return entry.committed?.state.needsAttention ?? false
    }

    /// The row badge. Without committed semantic attention (legacy daemon,
    /// or a first signal still settling) only `working` activity shows, as
    /// Working -- nothing else is invented, and nothing flickers while the
    /// first candidate waits out its window. A settling `unknown` (every
    /// launch and resume) shows nothing: the daemon said it isn't working.
    func badge(for agent: String, legacyActivity: LeoAgentRow.Activity) -> LeoAttentionBadge? {
        guard let entry = entries[agent], let committed = entry.committed else {
            let isSettlingUnknown = entries[agent]?.candidate?.signal.state == .unknown
            return legacyActivity == .working && !isSettlingUnknown ? .working : nil
        }
        return entry.isStale ? nil : LeoAttentionBadge(committed.state)
    }

    /// Agents needing attention that focus has not yet acknowledged.
    func dockCount(among agents: Set<String>) -> Int {
        agents.filter { agent in
            needsAttention(agent) && entries[agent]?.acknowledgedRevision != entries[agent]?.committed?.revision
        }.count
    }

    /// `agents` (in the caller's order) that currently need attention.
    func needingAttention(among agents: [String]) -> [String] { agents.filter(needsAttention) }
}
