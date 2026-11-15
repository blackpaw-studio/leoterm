import Foundation
import Testing

@testable import LeoKit

struct LeoPluginSupervisorTests {
    @Test func firstCrashRestartsAfterOneSecondThenFiveSeconds() {
        var supervisor = LeoPluginSupervisor()
        #expect(supervisor.recordCrash(reason: "killed", at: 0) == .restart(after: 1))
        #expect(supervisor.recordCrash(reason: "killed", at: 10) == .restart(after: 5))
    }

    @Test func thirdCrashWithinFiveMinutesDisablesWithTheReason() {
        var supervisor = LeoPluginSupervisor()
        _ = supervisor.recordCrash(reason: "a", at: 0)
        _ = supervisor.recordCrash(reason: "b", at: 100)
        let decision = supervisor.recordCrash(reason: "cpu limit", at: 299)
        #expect(decision == .disable(reason: "cpu limit"))
        #expect(supervisor.state == .disabled(reason: "cpu limit"))
    }

    @Test func crashesOutsideTheWindowRollOffSoBackoffRestarts() {
        var supervisor = LeoPluginSupervisor()
        _ = supervisor.recordCrash(reason: "a", at: 0)
        _ = supervisor.recordCrash(reason: "b", at: 100)
        // The first crash is now 301 s old, so only two count: second-step backoff.
        #expect(supervisor.recordCrash(reason: "c", at: 301) == .restart(after: 5))
        // 400 s later every earlier crash has rolled off.
        #expect(supervisor.recordCrash(reason: "d", at: 800) == .restart(after: 1))
    }

    @Test func aDisabledPluginStaysDisabledUntilReenabled() {
        var supervisor = LeoPluginSupervisor()
        for t in [0.0, 1, 2] { _ = supervisor.recordCrash(reason: "x", at: t) }
        #expect(supervisor.recordCrash(reason: "again", at: 3) == .disable(reason: "x"))
        supervisor.reenable()
        #expect(supervisor.state == .running)
        #expect(supervisor.recordCrash(reason: "fresh", at: 4) == .restart(after: 1))
    }

    @Test func backoffBeyondTheTableUsesTheLastStep() {
        var supervisor = LeoPluginSupervisor(maxCrashes: 5)
        let delays = (0..<5).map { i -> LeoPluginSupervisor.Decision in
            supervisor.recordCrash(reason: "x", at: Double(i))
        }
        #expect(delays == [.restart(after: 1), .restart(after: 5), .restart(after: 30), .restart(after: 30), .disable(reason: "x")])
    }
}
