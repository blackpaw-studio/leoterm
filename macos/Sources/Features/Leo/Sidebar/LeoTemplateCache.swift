import Foundation
import LeoKit

/// Single-flight cache for each connected host's template list, one slot
/// per host. Rows and the Agents-menu submenu both read through this instead of issuing their
/// own fetches, so N visible rows collapse into at most one outstanding
/// request. `refreshIfStale` is generic over the fetch itself (the caller
/// supplies how to get the templates -- local CLI vs. remote SSH exec) so
/// this type stays free of any daemon/CLI dependency and is trivial to
/// unit test in isolation.
///
/// Templates are host *configuration* -- they don't change when agents
/// spawn or stop -- so this cache is deliberately NOT invalidated by every
/// sidebar list refresh (that would fetch more often than a naive TTL once
/// the list refresh became SSE-driven). Hosts never share a slot, so
/// reading or invalidating one never evicts another (machines connect at
/// once); the caller invalidates explicitly on a user-initiated sidebar
/// refresh; `templateCacheTTL` below is only a backstop against a stale
/// cache outliving both of those (e.g. a template renamed on the daemon side
/// during a long idle window).
///
/// Concurrent callers while a fetch is in flight all await the SAME task
/// rather than starting their own. `invalidate()` bumps a generation
/// counter rather than clearing state synchronously underneath an
/// in-flight fetch: if a fetch that started before an `invalidate()` call
/// completes afterward, its result must not overwrite the cache with data
/// that's already considered stale.
actor LeoTemplateCache {
    /// Backstop TTL: even with no manual refresh, a cached value older than
    /// this is treated as stale on the next read.
    static let templateCacheTTL: TimeInterval = 5 * 60

    private enum State {
        case idle
        case fetching(Task<[LeoTemplate], Error>)
        case value([LeoTemplate], fetchedAt: Date)
    }

    /// One host's state plus a counter bumped by its invalidations, so an
    /// in-flight fetch that finishes afterwards cannot repopulate the slot.
    private struct Slot {
        var state: State = .idle
        var generation = 0
    }

    private let clock: @Sendable () -> Date
    private var slots: [LeoHostID: Slot] = [:]

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// `host`'s last successfully cached value, if any, without triggering a
    /// fetch or checking the TTL. `nil` while idle or mid-fetch.
    func current(for host: LeoHostID) -> [LeoTemplate]? {
        if case .value(let templates, _) = slots[host]?.state { return templates }
        return nil
    }

    /// Returns `host`'s cached templates if present and within
    /// `templateCacheTTL`, awaits an already in-flight fetch for it if one is
    /// running, or starts a new fetch via `fetch` otherwise. A failed fetch
    /// leaves the slot idle so the very next call retries rather than caching
    /// the failure.
    func refreshIfStale(
        for host: LeoHostID, _ fetch: @escaping @Sendable () async throws -> [LeoTemplate]
    ) async throws -> [LeoTemplate] {
        switch slots[host]?.state ?? .idle {
        case .value(let templates, let fetchedAt) where clock().timeIntervalSince(fetchedAt) < Self.templateCacheTTL:
            return templates
        case .value, .idle:
            return try await startFetch(for: host, fetch)
        case .fetching(let task):
            return try await task.value
        }
    }

    private func startFetch(
        for host: LeoHostID, _ fetch: @escaping @Sendable () async throws -> [LeoTemplate]
    ) async throws -> [LeoTemplate] {
        var slot = slots[host] ?? Slot()
        let requestGeneration = slot.generation
        let task = Task { try await fetch() }
        slot.state = .fetching(task)
        slots[host] = slot
        do {
            let templates = try await task.value
            if slots[host]?.generation == requestGeneration { slots[host]?.state = .value(templates, fetchedAt: clock()) }
            return templates
        } catch {
            if slots[host]?.generation == requestGeneration { slots[host]?.state = .idle }
            throw error
        }
    }

    /// Marks `host`'s slot stale. Does not cancel an in-flight fetch (its
    /// result is simply discarded on completion); the next reader always
    /// starts, or joins, a fresh fetch.
    func invalidate(for host: LeoHostID) {
        var slot = slots[host] ?? Slot()
        slot.generation += 1
        slot.state = .idle
        slots[host] = slot
    }

    /// `invalidate(for:)` for every host seen so far.
    func invalidate() {
        for host in slots.keys { invalidate(for: host) }
    }
}
