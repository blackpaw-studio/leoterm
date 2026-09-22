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
    /// The focused agent's name, only when it belongs to `host`.
    private var focusedAgent: String?
    /// The last `hello.boot_id` seen for `host`.
    private var bootID: String?

    /// The earliest moment a pending candidate can commit, if any.
    var nextDeadline: TimeInterval? { entries.values.compactMap(\.deadline).min() }

    // MARK: Connection lifecycle

    /// Clears every state, candidate and acknowledgement; the new host is
    /// silent until its first baseline.
    mutating func switchHost(_ host: LeoHostID) {
        self = LeoAttentionReducer()
        self.host = host
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

    /// Keeps states for display continuity but excludes them from counts,
    /// navigation and badges until the next baseline.
    mutating func disconnect() {
        beginRecovery()
        entries = entries.mapValues { entry in
            var entry = entry
            entry.isStale = true
            return entry
        }
    }

    /// Replaces every entry with the authoritative `/state` snapshot (even at
    /// a lower revision -- a restarted daemon starts over), then merges any
    /// newer buffered signals. Never produces transitions.
    mutating func applyBaseline(_ baseline: [String: LeoAttentionSignal]) {
        var merged = baseline
        for (agent, signal) in buffered where signal.revision > (merged[agent]?.revision ?? Int.min) {
            merged[agent] = signal
        }
        entries = merged.reduce(into: [:]) { result, item in
            let previous = entries[item.key]
            let keepsAcknowledgement = previous?.committed == item.value
            result[item.key] = Entry(
                committed: item.value,
                lastSeenRevision: item.value.revision,
                acknowledgedRevision: keepsAcknowledgement ? previous?.acknowledgedRevision : nil
            )
        }
        buffered = [:]
        isRecovering = false
        acknowledgeFocused()
    }

    // MARK: Signals and time

    mutating func receive(agent: String, signal: LeoAttentionSignal, now: TimeInterval) {
        if isRecovering {
            if signal.revision > (buffered[agent]?.revision ?? Int.min) { buffered[agent] = signal }
            return
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
            revision: signal.revision, shouldNotify: notifies
        )
    }

    // MARK: Focus and membership

    /// The agent whose attachment is focused (key window -> selected tab ->
    /// focused split), or `nil`. Acknowledges its current attention.
    mutating func focus(_ id: LeoAgentRow.ID?) {
        focusedAgent = id.flatMap { $0.host == host ? $0.name : nil }
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
    }

    /// Drops agents no longer in the agent list.
    mutating func retain(agents: Set<String>) {
        entries = entries.filter { agents.contains($0.key) }
        buffered = buffered.filter { agents.contains($0.key) }
    }

    // MARK: Queries

    func state(of agent: String) -> LeoAttentionState? { entries[agent]?.committed?.state }

    /// Whether the daemon has reported semantic attention for `agent`.
    func isSupported(_ agent: String) -> Bool { entries[agent] != nil }

    func isStale(_ agent: String) -> Bool { entries[agent]?.isStale ?? false }

    func needsAttention(_ agent: String) -> Bool {
        guard let entry = entries[agent], !entry.isStale else { return false }
        return entry.committed?.state.needsAttention ?? false
    }

    /// The row badge. Without semantic attention (legacy daemon) only
    /// `working` activity shows, as Working -- nothing else is invented.
    func badge(for agent: String, legacyActivity: LeoAgentRow.Activity) -> LeoAttentionBadge? {
        guard let entry = entries[agent] else { return legacyActivity == .working ? .working : nil }
        guard !entry.isStale, let committed = entry.committed else { return nil }
        return LeoAttentionBadge(committed.state)
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
