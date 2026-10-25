import Foundation
import LeoKit

/// One `LeoSidebarFeed` per shown machine, kept for as long as the machine
/// is shown: a reconnect or an edit of the machine reaches its feed as a new
/// connection generation, never as a new feed. A machine that leaves and
/// comes back gets a fresh feed, and the old one's late snapshots are
/// dropped, so the model's per-machine generation guard never meets an
/// older feed's numbers.
///
/// Every call to a feed goes through that feed's own ordered queue, so its
/// start, its connection phases and visibility changes land in the order
/// they were made. Every feed forwards Leo Chat, tagged with its machine.
@MainActor final class LeoMachineFeeds {
    /// What every feed shares.
    struct Dependencies {
        /// This Mac's daemon and activity, bound from the start (it needs no
        /// tunnel); a remote machine's arrive with its connection.
        let localDaemon: any LeoDaemonClient
        let localActivity: LeoSidebarActivitySource
        var sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
        var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var onManualRefresh: @MainActor @Sendable () -> Void = {}
        var onAttentionTransitions: @MainActor @Sendable ([LeoAttentionTransition]) -> Void = { _ in }
        /// Each machine's `chat.*` events and resyncs, in that machine's stream
        /// order, tagged with the machine.
        var onChat: @Sendable (LeoHostID, LeoChatFeedSignal) -> Void = { _, _ in }
        /// Every snapshot of a shown machine's current feed.
        var onSnapshot: @MainActor (LeoHostID, LeoSidebarSnapshot) -> Void = { _, _ in }
    }

    private typealias Command = @Sendable (LeoSidebarFeed) async -> Void

    private struct Entry {
        let id: UUID
        let feed: LeoSidebarFeed
        let commands: LeoOrderedRelay<Command>

        func send(_ command: @escaping Command) { commands.send(command) }
    }

    private let dependencies: Dependencies
    private var entries: [LeoHostID: Entry] = [:]
    private var isStarted = false
    private var isPollable = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// The shown machines, in order.
    private(set) var hosts: [LeoHostID] = []

    func contains(_ host: LeoHostID) -> Bool { entries[host] != nil }

    /// `host`'s current feed, if it is shown.
    func feed(for host: LeoHostID) -> LeoSidebarFeed? { entries[host]?.feed }

    /// Makes a feed for every newly shown machine (started at once once
    /// `start` has run) and stops the feed of every machine that left.
    func setMachines(_ shown: [LeoHostID]) {
        hosts = shown
        let kept = Set(shown)
        for (host, entry) in entries where !kept.contains(host) {
            entries[host] = nil
            entry.send { await $0.stop() }
        }
        for host in shown where entries[host] == nil {
            let entry = makeEntry(for: host)
            entries[host] = entry
            if isStarted { start(entry) }
        }
    }

    /// Starts every feed. Runs once.
    func start(pollable: Bool) {
        guard !isStarted else { return }
        isStarted = true
        isPollable = pollable
        hosts.compactMap { entries[$0] }.forEach(start)
    }

    func stop() {
        isStarted = false
        entries.values.forEach { $0.send { await $0.stop() } }
    }

    /// `host`'s connection moved on; ignored for a machine that isn't shown.
    func updateConnection(host: LeoHostID, generation: Int, phase: LeoSidebarConnectionPhase) {
        entries[host]?.send { await $0.updateConnection(host: host, generation: generation, phase: phase) }
    }

    func setPolling(_ pollable: Bool) {
        isPollable = pollable
        entries.values.forEach { $0.send { await $0.setPolling(pollable) } }
    }

    /// One liveness check per machine (a wake from sleep, D-061).
    func checkLiveness() {
        entries.values.forEach { $0.send { _ = await $0.checkLiveness() } }
    }

    /// Every feed's attention reducer learns the focused agent; each acts
    /// only on its own machine's.
    func setFocusedAgent(_ id: LeoAgentRow.ID?) {
        entries.values.forEach { $0.send { await $0.setFocusedAgent(id) } }
    }

    /// A list refresh on every machine.
    func refresh() {
        entries.values.forEach { $0.send { await $0.refresh() } }
    }

    func disconnect(_ host: LeoHostID, reason: String) {
        entries[host]?.send { await $0.disconnect(reason: reason) }
    }

    private func start(_ entry: Entry) {
        let pollable = isPollable
        entry.send { feed in
            await feed.start()
            await feed.setInitialPolling(pollable)
        }
    }

    private func makeEntry(for host: LeoHostID) -> Entry {
        let id = UUID()
        let dependencies = dependencies
        let isLocal = host == .local
        let onChat = dependencies.onChat
        let feed = LeoSidebarFeed(
            daemon: isLocal ? dependencies.localDaemon : LeoUnconnectedDaemon(host: host),
            activity: isLocal ? dependencies.localActivity : LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] }),
            sleep: dependencies.sleep,
            now: dependencies.now,
            onManualRefresh: dependencies.onManualRefresh,
            onAttentionTransitions: dependencies.onAttentionTransitions,
            onChat: { from, signal in if from == host { onChat(host, signal) } },
            sink: { [weak self] snapshot in self?.deliver(snapshot, from: host, feed: id) }
        )
        let entry = Entry(id: id, feed: feed, commands: LeoOrderedRelay { command in await command(feed) })
        // A remote machine has no daemon until its tunnel is up: it waits
        // as connecting, never asking the stand-in client for anything.
        if !isLocal { entry.send { await $0.updateConnection(host: host, generation: 0, phase: .connecting) } }
        return entry
    }

    private func deliver(_ snapshot: LeoSidebarSnapshot, from host: LeoHostID, feed id: UUID) {
        guard entries[host]?.id == id else { return }
        dependencies.onSnapshot(host, snapshot)
    }
}

/// A remote machine's feed's client before its first connection: every
/// call fails as unavailable. The feed never makes one, since it starts
/// out connecting.
private struct LeoUnconnectedDaemon: LeoDaemonClient {
    let host: LeoHostID

    private var unavailable: LeoDaemonError { .hostUnavailable("\(host.displayName) is not connected") }

    func listAgents() async throws -> [LeoAgent] { throw unavailable }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { throw unavailable }
    func start(_ name: String) async throws { throw unavailable }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { throw unavailable }
    func restart(_ name: String) async throws -> LeoAgent { throw unavailable }
    func reset(_ name: String) async throws { throw unavailable }
    func setTemplate(_ name: String, template: String) async throws { throw unavailable }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { throw unavailable }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { throw unavailable }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { throw unavailable }
    func logs(_ name: String, lines: Int?) async throws -> String { throw unavailable }
}
