import Testing

/// B-297: the focus gate asks a plain window whether this host can take key
/// status; it never takes CI's word for it.
@MainActor
struct LeoFocusProbeTests {
    private final class FakeHost {
        var polls = 0
        var activations = 0
        var closes = 0
        /// The attempt (1-based) on which the probe window becomes key; nil never.
        let becomesKeyOn: Int?

        init(becomesKeyOn: Int?) { self.becomesKeyOn = becomesKeyOn }

        func probe(attempts: Int = 3) -> LeoFocusProbe {
            LeoFocusProbe(
                activate: { self.activations += 1 },
                orderProbeKey: {},
                isProbeKey: {
                    self.polls += 1
                    return self.becomesKeyOn.map { self.polls >= $0 } ?? false
                },
                closeProbe: { self.closes += 1 },
                pause: {},
                attempts: attempts)
        }
    }

    @Test func aWindowThatNeverBecomesKeyIsUnavailableWithAReason() async {
        let host = FakeHost(becomesKeyOn: nil)

        let outcome = await host.probe().run()

        #expect(outcome == .unavailable(reason: LeoFocusProbe.unavailableReason))
        #expect(LeoFocusProbe.unavailableReason.contains("key window"))
        #expect(host.polls == 3)
        #expect(host.activations == 3)
        #expect(host.closes == 1)
    }

    @Test func aWindowThatBecomesKeyOnALaterAttemptIsAvailable() async {
        let host = FakeHost(becomesKeyOn: 2)

        let outcome = await host.probe().run()

        #expect(outcome == .available)
        #expect(host.polls == 2)
        #expect(host.closes == 1)
    }
}
