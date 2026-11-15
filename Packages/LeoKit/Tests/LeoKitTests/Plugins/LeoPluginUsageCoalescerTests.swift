import Foundation
import Testing

@testable import LeoKit

@MainActor struct LeoPluginUsageCoalescerTests {
    private final class Clock: @unchecked Sendable { var value: TimeInterval = 0 }

    private let alpha = LeoPluginAgentRef(machine: "localhost", name: "alpha")
    private let beta = LeoPluginAgentRef(machine: "localhost", name: "beta")
    private let clock = Clock()
    private let scheduler = PluginManualScheduler()
    private var fired: FiredBox { box }
    private let box = FiredBox()
    private let coalescer: LeoPluginUsageCoalescer

    @MainActor final class FiredBox { var agents: [LeoPluginAgentRef] = [] }

    init() {
        let clock = clock
        let scheduler = scheduler
        let box = box
        coalescer = LeoPluginUsageCoalescer(interval: 1, now: { clock.value }, scheduler: scheduler, fire: { box.agents.append($0) })
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func theFirstChangeForAnAgentFiresAtOnce() {
        coalescer.change(alpha)
        #expect(fired.agents == [alpha])
        #expect(scheduler.liveDelays.isEmpty)
    }

    @Test func aChangeInsideTheWindowWaitsForTheRestOfItAndFiresOnce() async {
        coalescer.change(alpha)
        clock.value = 0.3
        coalescer.change(alpha)
        #expect(fired.agents == [alpha])
        #expect(scheduler.liveDelays.count == 1)
        #expect(abs((scheduler.liveDelays.first ?? 0) - 0.7) < 1e-9)

        clock.value = 1.0
        scheduler.fireAll()
        await settle()
        #expect(fired.agents == [alpha, alpha])
    }

    @Test func aBurstOfChangesCollapsesIntoOneTrailingFire() async {
        coalescer.change(alpha)
        for step in 1...5 {
            clock.value = Double(step) * 0.1
            coalescer.change(alpha)
        }
        #expect(scheduler.liveDelays.count == 1)
        clock.value = 1.0
        scheduler.fireAll()
        await settle()
        #expect(fired.agents == [alpha, alpha])
    }

    @Test func aChangeAfterTheWindowFiresAtOnceAgain() {
        coalescer.change(alpha)
        clock.value = 1.5
        coalescer.change(alpha)
        #expect(fired.agents == [alpha, alpha])
        #expect(scheduler.liveDelays.isEmpty)
    }

    @Test func theTrailingFireStartsANewWindow() async {
        coalescer.change(alpha)
        clock.value = 0.5
        coalescer.change(alpha)
        clock.value = 1.0
        scheduler.fireAll()
        await settle()

        clock.value = 1.1
        coalescer.change(alpha)
        #expect(fired.agents == [alpha, alpha])
        // The manual scheduler keeps fired handles, so the new wait is the last one scheduled.
        #expect(abs((scheduler.liveDelays.last ?? 0) - 0.9) < 1e-9)
        scheduler.fireAll()
        await settle()
        #expect(fired.agents.count == 3)
    }

    @Test func agentsAreCoalescedIndependently() {
        coalescer.change(alpha)
        coalescer.change(beta)
        clock.value = 0.2
        coalescer.change(alpha)
        #expect(fired.agents == [alpha, beta])
        #expect(scheduler.liveDelays.count == 1)
    }

    @Test func cancelAllDropsAPendingTrailingFire() async {
        coalescer.change(alpha)
        clock.value = 0.2
        coalescer.change(alpha)
        coalescer.cancelAll()
        scheduler.fireAll()
        await settle()
        #expect(fired.agents == [alpha])
        // The window state is forgotten too: the next change fires at once.
        clock.value = 0.3
        coalescer.change(alpha)
        #expect(fired.agents == [alpha, alpha])
    }
}
