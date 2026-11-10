import Foundation
import Testing

@testable import LeoKit

/// A hand-advanced monotonic clock so no test sleeps.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 1000

    var now: TimeInterval { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

struct LeoPluginRateLimiterTests {
    private func makeLimiter(
        clock: FakeClock, perWindow: Int = 60, window: TimeInterval = 60, inFlight: Int = 4
    ) -> LeoPluginRateLimiter {
        LeoPluginRateLimiter(maxPerWindow: perWindow, window: window, maxInFlight: inFlight, now: { clock.now })
    }

    /// Acquires and immediately releases, so only the window limit is exercised.
    private func burn(_ limiter: LeoPluginRateLimiter, _ count: Int) {
        for _ in 0..<count {
            if case .granted(let permit) = limiter.acquire() { limiter.release(permit) }
        }
    }

    @Test func theSixtyFirstRequestInAMinuteIsRejectedWithARetryDelay() {
        let clock = FakeClock()
        let limiter = makeLimiter(clock: clock)
        burn(limiter, 60)
        clock.advance(10)
        guard case .rejected(.rateLimited(let retryAfter)) = limiter.acquire() else {
            Issue.record("expected rate limited")
            return
        }
        // The oldest request was 10 s ago, so a slot frees in 50 s.
        #expect(retryAfter == 50)
    }

    @Test func theWindowSlidesSoRequestsAgeOutOneByOne() {
        let clock = FakeClock()
        let limiter = makeLimiter(clock: clock)
        for _ in 0..<30 { burn(limiter, 1); clock.advance(1) }   // t = 0...29
        burn(limiter, 30)                                          // 30 more at t = 30; window full
        guard case .rejected = limiter.acquire() else {
            Issue.record("expected rejection at 60 requests")
            return
        }
        clock.advance(30)   // now 60 s after the first request: it ages out, the second (59 s old) does not
        guard case .granted = limiter.acquire() else { Issue.record("a request aged out and should free a slot"); return }
        if case .granted = limiter.acquire() { Issue.record("only one request had aged out") }
    }

    @Test func aRequestExactlyOneWindowOldNoLongerCounts() {
        let clock = FakeClock()
        let limiter = makeLimiter(clock: clock, perWindow: 1)
        burn(limiter, 1)
        clock.advance(59.999)
        if case .granted = limiter.acquire() { Issue.record("still inside the window") }
        clock.advance(0.001)
        guard case .granted = limiter.acquire() else {
            Issue.record("window should have elapsed")
            return
        }
    }

    @Test func aFifthConcurrentRequestIsRejectedUntilOneCompletes() {
        let clock = FakeClock()
        let limiter = makeLimiter(clock: clock)
        var permits: [LeoPluginRateLimitPermit] = []
        for _ in 0..<4 {
            guard case .granted(let permit) = limiter.acquire() else {
                Issue.record("first four should be granted")
                return
            }
            permits.append(permit)
        }
        guard case .rejected(.tooManyInFlight) = limiter.acquire() else {
            Issue.record("expected in-flight rejection")
            return
        }
        limiter.release(permits[0])
        guard case .granted = limiter.acquire() else {
            Issue.record("a freed slot should be reusable")
            return
        }
    }

    @Test func aRejectedRequestDoesNotConsumeTheWindow() {
        let clock = FakeClock()
        let limiter = makeLimiter(clock: clock, perWindow: 5, inFlight: 1)
        guard case .granted(let first) = limiter.acquire() else { Issue.record("granted"); return }
        for _ in 0..<20 { _ = limiter.acquire() }   // all rejected: one in flight
        limiter.release(first)
        burn(limiter, 4)   // 1 + 4 = 5 granted in the window, nothing more should be counted
        guard case .rejected(.rateLimited) = limiter.acquire() else {
            Issue.record("window should now be exactly full")
            return
        }
    }

    @Test func releasingTheSamePermitTwiceFreesOnlyOneSlot() {
        let clock = FakeClock()
        let limiter = makeLimiter(clock: clock, inFlight: 2)
        guard case .granted(let a) = limiter.acquire(), case .granted = limiter.acquire() else {
            Issue.record("two granted"); return
        }
        limiter.release(a)
        limiter.release(a)
        guard case .granted = limiter.acquire() else { Issue.record("one slot freed"); return }
        guard case .rejected(.tooManyInFlight) = limiter.acquire() else {
            Issue.record("double release must not free a second slot")
            return
        }
    }

    @Test func aPermitFromAnotherLimiterDoesNotFreeASlot() {
        let clock = FakeClock()
        let one = makeLimiter(clock: clock, inFlight: 1)
        let two = makeLimiter(clock: clock, inFlight: 1)
        guard case .granted = one.acquire(), case .granted(let foreign) = two.acquire() else {
            Issue.record("granted"); return
        }
        one.release(foreign)
        guard case .rejected(.tooManyInFlight) = one.acquire() else {
            Issue.record("foreign permit must be ignored")
            return
        }
    }

    @Test func theClockGoingBackwardsNeverFreesSlotsEarlyOrCrashes() {
        let clock = FakeClock()
        let limiter = makeLimiter(clock: clock, perWindow: 1)
        burn(limiter, 1)
        clock.advance(-500)
        guard case .rejected(.rateLimited(let retryAfter)) = limiter.acquire() else {
            Issue.record("a backwards clock must not grant")
            return
        }
        #expect(retryAfter >= 0 && retryAfter.isFinite)
    }

    @Test func concurrentAcquiresNeverExceedTheInFlightCap() async {
        let clock = FakeClock()
        let limiter = makeLimiter(clock: clock, perWindow: 1000)
        let granted = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    if case .granted = limiter.acquire() { return 1 }
                    return 0
                }
            }
            return await group.reduce(0, +)
        }
        #expect(granted == 4)
    }

    @Test func theDefaultsAreSixtyPerMinuteAndFourInFlight() {
        #expect(LeoPluginRateLimiter.defaultMaxPerWindow == 60)
        #expect(LeoPluginRateLimiter.defaultWindow == 60)
        #expect(LeoPluginRateLimiter.defaultMaxInFlight == 4)
    }
}
