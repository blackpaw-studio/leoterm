import Foundation
import Testing
@testable import Ghostty

struct LeoTemplateCacheTests {
    @Test func manyReadersUseOneFetch() async throws {
        let loader = TemplateLoader(values: [["one"]])
        let cache = LeoTemplateCache()

        async let first = cache.refreshIfStale { try await loader.load() }
        async let second = cache.refreshIfStale { try await loader.load() }
        async let third = cache.refreshIfStale { try await loader.load() }

        #expect(try await first.map(\.name) == ["one"])
        #expect(try await second.map(\.name) == ["one"])
        #expect(try await third.map(\.name) == ["one"])
        #expect(await loader.callCount == 1)
    }

    @Test func readersShareAnInFlightFetch() async throws {
        let loader = TemplateLoader(values: [["one"]], suspended: true)
        let cache = LeoTemplateCache()

        async let first = cache.refreshIfStale { try await loader.load() }
        await loader.waitForCalls(1)
        async let second = cache.refreshIfStale { try await loader.load() }
        await loader.waitForCalls(1)
        await loader.resume()

        _ = try await (first, second)
        #expect(await loader.callCount == 1)
    }

    @Test func invalidatingRefetchesOnNextRead() async throws {
        let loader = TemplateLoader(values: [["one"], ["two"]])
        let cache = LeoTemplateCache()

        #expect(try await cache.refreshIfStale { try await loader.load() }.map(\.name) == ["one"])
        await cache.invalidate()
        #expect(try await cache.refreshIfStale { try await loader.load() }.map(\.name) == ["two"])
        #expect(await loader.callCount == 2)
    }

    @Test func failedFetchRetriesOnNextRead() async throws {
        let loader = TemplateLoader(values: [["one"]], failures: 1)
        let cache = LeoTemplateCache()

        await #expect(throws: TemplateLoader.Error.unavailable) {
            try await cache.refreshIfStale { try await loader.load() }
        }
        #expect(try await cache.refreshIfStale { try await loader.load() }.map(\.name) == ["one"])
        #expect(await loader.callCount == 2)
    }

    /// An `invalidate()` that lands while a fetch is already in flight must
    /// not let that fetch's (now-stale) result repopulate the cache once it
    /// finally completes -- the next reader must still see a fresh fetch.
    @Test func invalidateDuringInFlightFetchDiscardsTheStaleCompletion() async throws {
        let loader = TemplateLoader(values: [["one"], ["two"]], suspended: true)
        let cache = LeoTemplateCache()

        async let inFlight = cache.refreshIfStale { try await loader.load() }
        await loader.waitForCalls(1)
        await cache.invalidate()
        await loader.resume()

        #expect(try await inFlight.map(\.name) == ["one"])
        #expect(try await cache.refreshIfStale { try await loader.load() }.map(\.name) == ["two"])
        #expect(await loader.callCount == 2)
    }

    @Test func staleCacheBeyondTTLRefetchesOnNextRead() async throws {
        let loader = TemplateLoader(values: [["one"], ["two"]])
        let clock = TestClock()
        let cache = LeoTemplateCache(clock: { clock.now })

        #expect(try await cache.refreshIfStale { try await loader.load() }.map(\.name) == ["one"])
        clock.now = clock.now.addingTimeInterval(LeoTemplateCache.templateCacheTTL - 1)
        #expect(try await cache.refreshIfStale { try await loader.load() }.map(\.name) == ["one"])
        #expect(await loader.callCount == 1)

        clock.now = clock.now.addingTimeInterval(2)
        #expect(try await cache.refreshIfStale { try await loader.load() }.map(\.name) == ["two"])
        #expect(await loader.callCount == 2)
    }
}

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 0)
}

private actor TemplateLoader {
    enum Error: Swift.Error, Equatable { case unavailable }

    private var values: [[String]]
    private var failures: Int
    private var suspended: Bool
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0

    init(values: [[String]], failures: Int = 0, suspended: Bool = false) {
        self.values = values
        self.failures = failures
        self.suspended = suspended
    }

    func load() async throws -> [LeoTemplate] {
        callCount += 1
        if suspended { await withCheckedContinuation { continuations.append($0) } }
        if failures > 0 { failures -= 1; throw Error.unavailable }
        return values.removeFirst().map { LeoTemplate(name: $0) }
    }

    func waitForCalls(_ expected: Int) async {
        while callCount < expected { await Task.yield() }
    }

    func resume() {
        suspended = false
        continuations.forEach { $0.resume() }
        continuations = []
    }
}
