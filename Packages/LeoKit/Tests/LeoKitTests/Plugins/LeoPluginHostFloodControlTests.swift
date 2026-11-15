import Testing

@testable import LeoKit

struct LeoPluginRequestQuotaTests {
    @Test func requestsUnderBothLimitsPass() {
        var quota = LeoPluginRequestQuota(maxRequests: 3, maxBytes: 100)
        #expect(quota.record(requestBytes: 10) == nil)
        #expect(quota.record(requestBytes: 10) == nil)
        #expect(quota.record(requestBytes: 10) == nil)
    }

    @Test func oneRequestTooManyIsAViolation() {
        var quota = LeoPluginRequestQuota(maxRequests: 3, maxBytes: 1_000)
        for _ in 0..<3 { _ = quota.record(requestBytes: 1) }
        let reason = quota.record(requestBytes: 1)
        #expect(reason?.contains("3 requests") == true)
    }

    @Test func bytesOverTheCapAreAViolation() {
        var quota = LeoPluginRequestQuota(maxRequests: 1_000, maxBytes: 100)
        #expect(quota.record(requestBytes: 60) == nil)
        #expect(quota.record(requestBytes: 40) == nil)  // exactly at the cap
        #expect(quota.record(requestBytes: 1)?.contains("bytes") == true)
    }

    @Test func resetGivesTheNextHandlerAFreshQuota() {
        var quota = LeoPluginRequestQuota(maxRequests: 2, maxBytes: 100)
        _ = quota.record(requestBytes: 50)
        _ = quota.record(requestBytes: 50)
        quota.reset()
        #expect(quota.record(requestBytes: 50) == nil)
    }

    @Test func defaultsAreTheSpecifiedCaps() {
        #expect(LeoPluginRequestQuota.defaultMaxRequests == 256)
        #expect(LeoPluginRequestQuota.defaultMaxBytes == 8 * 1_048_576)
    }
}

struct LeoPluginBackpressureTests {
    @Test func suspendsAboveTheHighWaterMarkOnly() {
        var pressure = LeoPluginBackpressure(highWater: 3, lowWater: 1)
        #expect(pressure.enqueued() == .none)
        #expect(pressure.enqueued() == .none)
        #expect(pressure.enqueued() == .none)  // at the mark
        #expect(pressure.enqueued() == .suspend)  // above it
        #expect(pressure.outstanding == 4)
    }

    @Test func resumesOnceDrainedToTheLowWaterMark() {
        var pressure = LeoPluginBackpressure(highWater: 3, lowWater: 1)
        for _ in 0..<4 { _ = pressure.enqueued() }
        #expect(pressure.delivered() == .none)  // 3
        #expect(pressure.delivered() == .none)  // 2
        #expect(pressure.delivered() == .resume)  // 1
    }

    @Test func deliveredNeverGoesNegative() {
        var pressure = LeoPluginBackpressure(highWater: 3, lowWater: 1)
        _ = pressure.delivered()
        #expect(pressure.outstanding == 0)
    }
}
