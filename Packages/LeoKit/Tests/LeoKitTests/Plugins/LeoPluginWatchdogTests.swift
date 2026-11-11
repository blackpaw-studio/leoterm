import Foundation
import Testing

@testable import LeoKit

private final class FakeUsage: @unchecked Sendable {
    var cpu: Double = 5
    var footprintMB: Double = 10
    var alive = true

    func read() -> LeoPluginUsage? {
        alive ? LeoPluginUsage(cpuSeconds: cpu, footprintBytes: UInt64(footprintMB * 1_048_576)) : nil
    }
}

struct LeoPluginWatchdogTests {
    private func makeWatchdog(_ usage: FakeUsage) -> LeoPluginWatchdog {
        LeoPluginWatchdog(readUsage: { usage.read() })
    }

    @Test func cpuUnderTheBudgetIsFine() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        usage.cpu += 1.9
        #expect(dog.poll(at: 0.25) == .ok)
    }

    @Test func cpuOverTheBudgetKillsWithAReason() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        usage.cpu += 2.1
        guard case .kill(let reason) = dog.poll(at: 0.25) else {
            Issue.record("expected kill")
            return
        }
        #expect(reason.contains("CPU"))
    }

    @Test func wallTimeWithoutCPUNeverKills() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        for tick in 1...100 { #expect(dog.poll(at: Double(tick) * 0.25) == .ok) }
    }

    @Test func cpuBurnedBeforeTheHandlerStartedIsNotCharged() {
        let usage = FakeUsage()
        usage.cpu = 1000
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        usage.cpu += 0.5
        #expect(dog.poll(at: 0.25) == .ok)
    }

    @Test func memoryOverTheCapKills() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        usage.footprintMB = 257
        guard case .kill(let reason) = dog.poll(at: 0.25) else {
            Issue.record("expected kill")
            return
        }
        #expect(reason.contains("256"))
    }

    @Test func memoryAtTheCapIsFine() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        usage.footprintMB = 256
        #expect(dog.poll(at: 0.25) == .ok)
    }

    @Test func memoryIsCheckedOncePerSecond() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        #expect(dog.poll(at: 0.25) == .ok)  // first poll reads memory
        usage.footprintMB = 300
        #expect(dog.poll(at: 0.5) == .ok)  // within the same second: not re-read
        if case .kill = dog.poll(at: 1.3) {} else { Issue.record("expected kill at the next memory check") }
    }

    @Test func handlerCPUBudgetIsNotAppliedWhileIdle() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        _ = dog.poll(at: 0)  // idle baseline
        usage.cpu += 0.4  // under the idle allowance for one window
        #expect(dog.poll(at: 1) == .ok)
    }

    @Test func memoryOverTheCapKillsEvenWhileIdle() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        usage.footprintMB = 400
        guard case .kill(let reason) = dog.poll(at: 5) else {
            Issue.record("expected kill")
            return
        }
        #expect(reason.contains("256"))
    }

    @Test func memoryIsCheckedImmediatelyWhenAHandlerFinishes() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        #expect(dog.poll(at: 0.25) == .ok)  // memory read; next scheduled read is a second away
        usage.footprintMB = 400
        guard case .kill(let reason) = dog.handlerFinished(at: 0.3) else {
            Issue.record("expected kill on done")
            return
        }
        #expect(reason.contains("256"))
    }

    @Test func cpuGrowthWhileIdleKills() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        _ = dog.handlerFinished(at: 0.1)
        usage.cpu += 0.9  // a background loop burning ~all of a one-second window
        guard case .kill(let reason) = dog.poll(at: 1.2) else {
            Issue.record("expected kill")
            return
        }
        #expect(reason.contains("idle"))
    }

    @Test func idleCPUBudgetScalesWithAStretchedPollGap() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        _ = dog.poll(at: 0)
        usage.cpu += 0.6  // 5% of a 12 s gap (App Nap / timer coalescing)
        #expect(dog.poll(at: 12) == .ok)
    }

    @Test func idleCPUOverTheRateInANormalGapKills() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        _ = dog.poll(at: 0)
        usage.cpu += 0.6  // 60% of a 1 s gap
        guard case .kill = dog.poll(at: 1) else {
            Issue.record("expected kill")
            return
        }
    }

    @Test func idleCPUIsMeasuredPerWindowNotCumulatively() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        _ = dog.poll(at: 0)
        for second in 1...20 {
            usage.cpu += 0.1  // a light, steady trickle stays under the threshold
            #expect(dog.poll(at: Double(second)) == .ok)
        }
    }

    @Test func cpuSpentRunningAHandlerDoesNotCountAsIdleGrowth() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        usage.cpu += 1.5
        _ = dog.handlerFinished(at: 1.5)
        usage.cpu += 0.1
        #expect(dog.poll(at: 2) == .ok)
    }

    @Test func queuedHandlersAreEachGivenTheirOwnBudget() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        dog.handlerStarted(at: 0)  // queued behind the first
        usage.cpu += 1.5
        _ = dog.handlerFinished(at: 1)  // second starts running now
        usage.cpu += 1.5  // 3 s since the first started, 1.5 s for the second
        #expect(dog.poll(at: 1.25) == .ok)
        usage.cpu += 1
        if case .kill = dog.poll(at: 1.5) {} else { Issue.record("expected kill for the second handler") }
    }

    @Test func aVanishedProcessIsNotAKill() {
        let usage = FakeUsage()
        var dog = makeWatchdog(usage)
        dog.handlerStarted(at: 0)
        usage.alive = false
        #expect(dog.poll(at: 0.25) == .ok)
    }

    @Test func tickConversionUsesTheTimebase() {
        // Apple Silicon: 125/3 ns per tick, so 24_000_000 ticks is one second.
        #expect(abs(LeoPluginUsage.seconds(fromMachTicks: 24_000_000, numer: 125, denom: 3) - 1) < 1e-9)
        #expect(LeoPluginUsage.seconds(fromMachTicks: 1_000_000_000, numer: 1, denom: 1) == 1)
    }
}
