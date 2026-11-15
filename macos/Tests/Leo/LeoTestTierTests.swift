import Testing

@testable import Ghostty

@MainActor
struct LeoTestTierTests {
    @Test func hostTierIsOffWhenUnset() {
        #expect(!LeoTestTier(environment: [:]).runsHostTests)
    }

    @Test(arguments: ["0", "", "true", "yes", " 1"])
    func hostTierIsOffForAnythingButOne(value: String) {
        #expect(!LeoTestTier(environment: ["LEO_HOST_TESTS": value]).runsHostTests)
    }

    @Test func hostTierIsOnForExactlyOne() {
        #expect(LeoTestTier(environment: ["LEO_HOST_TESTS": "1"]).runsHostTests)
    }

    @Test func focusProbeNeverRunsWhenTierIsOff() async {
        var probeBuilt = false
        let available = await LeoTestTier(environment: [:]).focusAvailable {
            probeBuilt = true
            return Self.availableProbe
        }
        #expect(!available)
        #expect(!probeBuilt)
    }

    @Test func focusProbeDecidesWhenTierIsOn() async {
        let tier = LeoTestTier(environment: ["LEO_HOST_TESTS": "1"])
        #expect(await tier.focusAvailable { Self.availableProbe })
        #expect(!(await tier.focusAvailable { Self.unavailableProbe }))
    }

    private static var availableProbe: LeoFocusProbe {
        LeoFocusProbe(
            activate: {}, orderProbeKey: {}, isProbeKey: { true }, closeProbe: {},
            pause: {}, attempts: 1)
    }

    private static var unavailableProbe: LeoFocusProbe {
        LeoFocusProbe(
            activate: {}, orderProbeKey: {}, isProbeKey: { false }, closeProbe: {},
            pause: {}, attempts: 1)
    }
}
