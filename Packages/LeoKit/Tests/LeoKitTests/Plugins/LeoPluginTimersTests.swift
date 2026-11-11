import Foundation
import Testing

@testable import LeoKit

/// A hand-cranked scheduler: nothing fires until the test says so.
private final class ManualScheduler: LeoPluginTimerScheduling, @unchecked Sendable {
    final class Entry: LeoPluginTimerHandle, @unchecked Sendable {
        let delay: TimeInterval
        let repeating: Bool
        let action: @Sendable () -> Void
        var cancelled = false
        init(delay: TimeInterval, repeating: Bool, action: @escaping @Sendable () -> Void) {
            self.delay = delay; self.repeating = repeating; self.action = action
        }
        func cancel() { cancelled = true }
    }

    private let lock = NSLock()
    private(set) var entries: [Entry] = []

    func schedule(after delay: TimeInterval, repeating: Bool, _ action: @escaping @Sendable () -> Void) -> any LeoPluginTimerHandle {
        let entry = Entry(delay: delay, repeating: repeating, action: action)
        lock.withLock { entries.append(entry) }
        return entry
    }

    var live: [Entry] { lock.withLock { entries.filter { !$0.cancelled } } }
}

private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func record(_ id: String) { lock.withLock { ids.append(id) } }
    var all: [String] { lock.withLock { ids } }
}

private func makeTimers(_ scheduler: ManualScheduler, _ fired: Fired, visible: Bool = true) -> LeoPluginTimers {
    let timers = LeoPluginTimers(scheduler: scheduler) { fired.record($0) }
    timers.setSlotVisible(visible)
    return timers
}

struct LeoPluginTimersTests {
    @Test func aPeriodicTimerRepeatsAtItsInterval() throws {
        let scheduler = ManualScheduler()
        let fired = Fired()
        let timers = makeTimers(scheduler, fired)
        try timers.startPeriodic(id: "t1", seconds: 60)
        let entry = try #require(scheduler.live.first)
        #expect(entry.repeating && entry.delay == 60)
        entry.action()
        entry.action()
        #expect(fired.all == ["t1", "t1"])
    }

    @Test(arguments: [0.0, 1, 59.9, -5, Double.nan, Double.infinity])
    func refusesAPeriodicIntervalUnderSixtySeconds(seconds: Double) {
        let timers = makeTimers(ManualScheduler(), Fired())
        #expect(throws: LeoPluginTimerError.self) { try timers.startPeriodic(id: "t", seconds: seconds) }
    }

    @Test(arguments: [0.0, 0.5, -1, Double.nan, Double.infinity])
    func refusesAnAfterDelayUnderOneSecond(seconds: Double) {
        let timers = makeTimers(ManualScheduler(), Fired())
        #expect(throws: LeoPluginTimerError.self) { try timers.startAfter(id: "t", seconds: seconds) }
    }

    @Test(arguments: [1e19, Double.greatestFiniteMagnitude, 604_800.5, 604_801])
    func clampsAnOversizedIntervalOrDelayToSevenDays(seconds: Double) throws {
        let scheduler = ManualScheduler()
        let timers = makeTimers(scheduler, Fired())
        try timers.startPeriodic(id: "p", seconds: seconds)
        try timers.startAfter(id: "a", seconds: seconds)
        #expect(scheduler.live.map(\.delay) == [LeoPluginTimers.maximumInterval, LeoPluginTimers.maximumInterval])
        #expect(LeoPluginTimers.maximumInterval == 7 * 24 * 3600)
    }

    @Test func acceptsTheExactEdges() throws {
        let scheduler = ManualScheduler()
        let timers = makeTimers(scheduler, Fired())
        try timers.startPeriodic(id: "lo", seconds: 60)
        try timers.startPeriodic(id: "hi", seconds: 604_800)
        try timers.startAfter(id: "alo", seconds: 1)
        try timers.startAfter(id: "ahi", seconds: 604_800)
        #expect(scheduler.live.map(\.delay) == [60, 604_800, 1, 604_800])
    }

    @Test(arguments: [1e19, Double.infinity, -Double.infinity, Double.nan, -1e19, 0, 604_800, 0.0004, 60.0004])
    func theDispatchSchedulerBuildsIntervalsFromBoundedMilliseconds(seconds: Double) {
        let milliseconds = LeoPluginDispatchTimerScheduler.intervalMilliseconds(for: seconds)
        #expect((1...604_800_000).contains(milliseconds))
    }

    @Test func theRealSchedulerSurvivesAHugeDelay() {
        let handle = LeoPluginDispatchTimerScheduler().schedule(after: 1e19, repeating: true) {}
        handle.cancel()
    }

    @Test func aOneShotFiresOnceAndThenForgetsItself() throws {
        let scheduler = ManualScheduler()
        let fired = Fired()
        let timers = makeTimers(scheduler, fired)
        try timers.startAfter(id: "poll", seconds: 5)
        let entry = try #require(scheduler.live.first)
        #expect(!entry.repeating && entry.delay == 5)
        entry.action()
        entry.action()
        #expect(fired.all == ["poll"])
        #expect(timers.activeIDs.isEmpty)
    }

    @Test func aOneShotThatElapsesWhileNoSlotIsVisibleWaitsForVisibility() throws {
        let scheduler = ManualScheduler()
        let fired = Fired()
        let timers = makeTimers(scheduler, fired, visible: false)
        try timers.startAfter(id: "poll", seconds: 5)
        try #require(scheduler.live.first).action()
        #expect(fired.all.isEmpty)
        timers.setSlotVisible(true)
        #expect(fired.all == ["poll"])
        timers.setSlotVisible(false)
        timers.setSlotVisible(true)
        #expect(fired.all == ["poll"])
    }

    @Test func periodicTimersFireRegardlessOfSlotVisibility() throws {
        let scheduler = ManualScheduler()
        let fired = Fired()
        let timers = makeTimers(scheduler, fired, visible: false)
        try timers.startPeriodic(id: "refresh", seconds: 60)
        try #require(scheduler.live.first).action()
        #expect(fired.all == ["refresh"])
    }

    @Test func startingAnExistingIdReplacesItsTimer() throws {
        let scheduler = ManualScheduler()
        let timers = makeTimers(scheduler, Fired())
        try timers.startPeriodic(id: "t", seconds: 60)
        try timers.startPeriodic(id: "t", seconds: 120)
        #expect(scheduler.live.count == 1)
        #expect(scheduler.live.first?.delay == 120)
    }

    @Test func stopCancelsOneTimerAndStopAllCancelsEveryOne() throws {
        let scheduler = ManualScheduler()
        let timers = makeTimers(scheduler, Fired())
        try timers.startPeriodic(id: "a", seconds: 60)
        try timers.startPeriodic(id: "b", seconds: 60)
        try timers.startAfter(id: "c", seconds: 5)
        timers.stop(id: "a")
        #expect(timers.activeIDs == ["b", "c"])
        timers.stopAll()
        #expect(scheduler.live.isEmpty)
        #expect(timers.activeIDs.isEmpty)
    }

    @Test func aStoppedTimerThatStillFiresIsIgnored() throws {
        let scheduler = ManualScheduler()
        let fired = Fired()
        let timers = makeTimers(scheduler, fired)
        try timers.startPeriodic(id: "a", seconds: 60)
        let entry = try #require(scheduler.live.first)
        timers.stopAll()
        entry.action()
        #expect(fired.all.isEmpty)
    }

    @Test func aStoppedHeldOneShotNeverFiresOnVisibility() throws {
        let scheduler = ManualScheduler()
        let fired = Fired()
        let timers = makeTimers(scheduler, fired, visible: false)
        try timers.startAfter(id: "poll", seconds: 5)
        try #require(scheduler.live.first).action()
        timers.stop(id: "poll")
        timers.setSlotVisible(true)
        #expect(fired.all.isEmpty)
    }

    @Test func capsTheNumberOfTimersPerPlugin() throws {
        let timers = makeTimers(ManualScheduler(), Fired())
        for index in 0..<LeoPluginTimers.maxTimers { try timers.startPeriodic(id: "t\(index)", seconds: 60) }
        #expect(throws: LeoPluginTimerError.self) { try timers.startPeriodic(id: "extra", seconds: 60) }
        // Replacing an existing id is not a new timer.
        try timers.startPeriodic(id: "t0", seconds: 90)
    }

    @Test func stoppingAHostThatNeverStartedTimersIsHarmless() {
        makeTimers(ManualScheduler(), Fired()).stopAll()
    }
}
