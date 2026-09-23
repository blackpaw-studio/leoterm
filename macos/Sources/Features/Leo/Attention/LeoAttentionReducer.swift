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
/// - Signals at or below an agent name's last-seen revision this boot are
///   duplicates: revisions never repeat per (boot, name), even across a
///   delete, recreate or rename.
/// - Baselines (and events buffered while recovering) commit silently.
/// - Disconnect marks everything stale until the next baseline.
/// - Focusing an agent acknowledges its Dock contribution; the badge stays.
struct LeoAttentionReducer: Equatable, Sendable {
    static let stabilityInterval: TimeInterval = 0.3

    private struct Candidate: Equatable, Sendable {
        var signal: LeoAttentionSignal
        let since: TimeInterval
    }

    /// Display state only; the revision floor and acknowledgement live in
    /// per-name maps, so they outlive it.
    private struct Entry: Equatable, Sendable {
        var committed: LeoAttentionSignal?
        var candidate: Candidate?
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
    private(set) var focusedID: LeoAgentRow.ID?
    /// The last `hello.boot_id` seen for `host`.
    private var bootID: String?
    /// The highest revision seen per agent name this boot. The daemon's
    /// counter is per name per boot and survives delete, recreate and
    /// rename, so `(bootID, name, revision)` is unique: a signal at or below
    /// it is a duplicate. Kept after an agent's display state goes; cleared
    /// on a host switch or daemon restart, so one floor per name per boot.
    private var floors: [String: Int] = [:]
    /// The revision focus acknowledged per agent name this boot. Revisions
    /// are unique, so it outlives display state like `floors`.
    private var acknowledged: [String: Int] = [:]
    /// Bumped by every `resetAgent`; see `membershipMark`.
    private var spawnCount = 0
    /// The `spawnCount` at each agent's latest spawn this boot.
    private var spawnMarks: [String: Int] = [:]

    /// The focused agent's name, only when it belongs to `host`.
    private var focusedAgent: String? { focusedID.flatMap { $0.host == host ? $0.name : nil } }

    /// The earliest moment a pending candidate can commit, if any.
    var nextDeadline: TimeInterval? { entries.values.compactMap(\.deadline).min() }

    // MARK: Connection lifecycle

    /// Clears every state, candidate, floor and acknowledgement; the new
    /// host is silent until its first baseline. Focus and the spawn count
    /// carry over.
    mutating func switchHost(_ host: LeoHostID) {
        var next = LeoAttentionReducer()
        next.host = host
        next.focusedID = focusedID
        next.spawnCount = spawnCount
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
        floors = [:]
        acknowledged = [:]
        spawnMarks = [:]
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
    /// - In recovery the snapshot wins: candidates were cancelled, so a
    ///   revision equal to the floor may still be uncommitted.
    /// - Outside recovery live signals already applied are at least as new
    ///   as the snapshot, so those entries (and their candidates) stay.
    /// - Deletion is the agent list's call (`retain`), never the snapshot's:
    ///   an agent can be missing from it only because its field isn't set
    ///   yet (a fresh agent) or didn't decode. Outside recovery a live
    ///   (non-stale) entry the snapshot lacks is kept; in recovery its state
    ///   goes (the daemon didn't report it), its floor stays.
    mutating func applyBaseline(_ baseline: [String: LeoAttentionSignal]) {
        let wasRecovering = isRecovering
        let merged = buffered.reduce(into: baseline) { result, item in
            if item.value.revision > (result[item.key]?.revision ?? Int.min) { result[item.key] = item.value }
        }
        let kept = entries.filter { agent, entry in
            guard let signal = merged[agent] else { return !wasRecovering && !entry.isStale }
            return !wasRecovering && revisionFloor(agent) >= signal.revision
        }
        let fresh = merged.filter { kept[$0.key] == nil }.mapValues { Entry(committed: $0) }
        entries = kept.merging(fresh) { current, _ in current }
        floors = merged.reduce(into: floors) { result, item in result[item.key] = max(revisionFloor(item.key), item.value.revision) }
        buffered = [:]
        isRecovering = false
        acknowledgeFocused()
    }

    // MARK: Signals and time

    private func revisionFloor(_ agent: String) -> Int { floors[agent] ?? Int.min }

    mutating func receive(agent: String, signal: LeoAttentionSignal, now: TimeInterval) {
        guard signal.revision > revisionFloor(agent) else { return }
        if isRecovering {
            if signal.revision > (buffered[agent]?.revision ?? Int.min) { buffered[agent] = signal }
            return
        }
        floors[agent] = signal.revision
        var entry = entries[agent] ?? Entry()
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
        if isFocused && signal.state.needsAttention { acknowledged[agent] = signal.revision }
        entries[agent] = entry
        let notifies = !isFocused && (signal.state == .needsInput || signal.state == .finished)
        return LeoAttentionTransition(
            id: LeoAgentRow.ID(host: host, name: agent), from: from, to: signal.state,
            revision: signal.revision, shouldNotify: notifies, bootID: bootID
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
        guard let agent = focusedAgent, let committed = entries[agent]?.committed,
              committed.state.needsAttention else { return }
        acknowledged[agent] = committed.revision
    }

    /// A newly spawned agent has no state yet, whatever an earlier agent
    /// of that name had. Its revisions continue above the name's floor.
    mutating func resetAgent(_ name: String) {
        entries[name] = nil
        buffered[name] = nil
        spawnCount += 1
        spawnMarks[name] = spawnCount
    }

    /// Pass the value read when a list fetch starts to `retain`, so the
    /// list can't drop an agent spawned (reset) after it was fetched.
    var membershipMark: Int { spawnCount }

    /// Drops the display state of agents no longer in the agent list; their
    /// floors stay. Agents spawned after `mark` are newer than the list and
    /// stay.
    mutating func retain(agents: Set<String>, listedSince mark: Int? = nil) {
        let newer = mark.map { mark in Set(spawnMarks.filter { $0.value > mark }.keys) } ?? []
        let listed = agents.union(newer).contains
        entries = entries.filter { listed($0.key) }
        buffered = buffered.filter { listed($0.key) }
    }

    // MARK: Queries

    func state(of agent: String) -> LeoAttentionState? { entries[agent]?.committed?.state }

    /// True until a baseline commits for the current host (buffering live signals).
    var isAwaitingBaseline: Bool { isRecovering }

    /// Whether the daemon has reported semantic attention for `agent`.
    func isSupported(_ agent: String) -> Bool { entries[agent] != nil }

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
            needsAttention(agent) && acknowledged[agent] != entries[agent]?.committed?.revision
        }.count
    }

    /// `agents` (in the caller's order) that currently need attention.
    func needingAttention(among agents: [String]) -> [String] { agents.filter(needsAttention) }
}
