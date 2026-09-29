import Foundation

/// Single-flight cache for one host connection's template list. Rows and
/// the Agents-menu submenu both read through this instead of issuing their
/// own fetches, so N visible rows collapse into at most one outstanding
/// request. `refreshIfStale` is generic over the fetch itself (the caller
/// supplies how to get the templates -- local CLI vs. remote SSH exec) so
/// this type stays free of any daemon/CLI dependency and is trivial to
/// unit test in isolation.
///
/// Templates are host *configuration* -- they don't change when agents
/// spawn or stop -- so this cache is deliberately NOT invalidated by every
/// sidebar list refresh (that would fetch more often than a naive TTL once
/// the list refresh became SSE-driven). A host switch invalidates through
/// `refreshIfStale(for:_:)`; the caller invalidates explicitly on a
/// user-initiated sidebar refresh; `templateCacheTTL`
/// below is only a backstop against a stale cache outliving both of those
/// (e.g. a template renamed on the daemon side during a long idle window).
///
/// Concurrent callers while a fetch is in flight all await the SAME task
/// rather than starting their own. `invalidate()` bumps a generation
/// counter rather than clearing state synchronously underneath an
/// in-flight fetch: if a fetch that started before an `invalidate()` call
/// completes afterward, its result must not overwrite the cache with data
/// that's already considered stale.
actor LeoTemplateCache {
    /// Backstop TTL: even with no host switch or manual refresh, a cached
    /// value older than this is treated as stale on the next read.
    static let templateCacheTTL: TimeInterval = 5 * 60

    private enum State {
        case idle
        case fetching(Task<[LeoTemplate], Error>)
        case value([LeoTemplate], fetchedAt: Date)
    }

    private let clock: @Sendable () -> Date
    private var state: State = .idle
    private var generation = 0
    /// The host `state` belongs to, once `refreshIfStale(for:_:)` is used.
    private var host: LeoHostID?

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// The last successfully cached value, if any, without triggering a
    /// fetch or checking the TTL. `nil` while idle or mid-fetch.
    var current: [LeoTemplate]? {
        if case .value(let templates, _) = state { return templates }
        return nil
    }

    /// Returns the cached templates if present and within `templateCacheTTL`,
    /// awaits an already in-flight fetch if one is running, or starts a new
    /// fetch via `fetch` otherwise. A failed fetch leaves the cache idle so
    /// the very next call retries rather than caching the failure.
    func refreshIfStale(_ fetch: @escaping @Sendable () async throws -> [LeoTemplate]) async throws -> [LeoTemplate] {
        switch state {
        case .value(let templates, let fetchedAt) where clock().timeIntervalSince(fetchedAt) < Self.templateCacheTTL:
            return templates
        case .value, .idle:
            return try await startFetch(fetch)
        case .fetching(let task):
            return try await task.value
        }
    }

    /// `refreshIfStale`, scoped to `host`: a read for a different host than
    /// the cached (or in-flight) one invalidates first, inside the actor,
    /// so no reader can ever see or join the previous host's templates
    /// (B-054).
    func refreshIfStale(
        for host: LeoHostID, _ fetch: @escaping @Sendable () async throws -> [LeoTemplate]
    ) async throws -> [LeoTemplate] {
        if host != self.host {
            invalidate()
            self.host = host
        }
        return try await refreshIfStale(fetch)
    }

    private func startFetch(_ fetch: @escaping @Sendable () async throws -> [LeoTemplate]) async throws -> [LeoTemplate] {
        let requestGeneration = generation
        let task = Task { try await fetch() }
        state = .fetching(task)
        do {
            let templates = try await task.value
            if generation == requestGeneration { state = .value(templates, fetchedAt: clock()) }
            return templates
        } catch {
            if generation == requestGeneration { state = .idle }
            throw error
        }
    }

    /// Marks the cache stale. Does not cancel an in-flight fetch (its
    /// result is simply discarded on completion); the next reader always
    /// starts, or joins, a fresh fetch.
    func invalidate() {
        generation += 1
        state = .idle
    }
}
