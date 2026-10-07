import AppKit

@testable import Ghostty

/// AppKit's event loop as `-[NSApplication run]` runs it, for tests of what
/// an idle app keeps alive (B-143). Each wait for an event happens inside an
/// autorelease pool of its own, drained once that event has been handled --
/// and only then -- and every wait starts by autoreleasing each of the
/// app's windows (`nextEventMatchingMask` copies `NSApp.windows` for its
/// gesture recognizers). A window closed while no event is being handled
/// therefore lives until the next event arrives.
///
/// The test host can't show that: its loop (XCTest's waiter) never drains
/// between waits, so any window that lived through one of its turns
/// outlives the test. A test that opens, closes and lets go of a window
/// inside this loop sees what the app would -- as long as it does all of
/// it here, every step inside `turn` or `autoreleasepool`, since anything
/// autoreleased outside them lands in the host's pool for good.
///
/// The loop runs from a run-loop block, not a main-queue turn, so the
/// main-queue work its steps queue (a window's presentation, the launch
/// tracker's close) runs inside its waits. Only application-defined events
/// end a wait -- in `idle`, only the loop's own and the wakes posted for the
/// window it waits on -- and the app's other events stay queued until the
/// loop returns, so no unrelated event, such as a wake for a window an
/// earlier test closed, drains a pool early. Other suites' main-actor work
/// runs inside it while it runs.
@MainActor final class LeoIdleEventLoop {
    /// The longest a `turn` waits for an event.
    private static let turnWait: TimeInterval = 0.01

    /// How often an idle wait checks whether it can stop.
    private static let idleCheckInterval: TimeInterval = 0.05

    /// The subtype of the events the loop posts to end its own waits.
    private static let stopSubtype: Int16 = 0x4C49

    private init() {}

    /// Runs `body` inside the loop; returns what it returned.
    static func run<T>(_ body: @escaping @MainActor (LeoIdleEventLoop) -> T) async -> T {
        await withCheckedContinuation { continuation in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    continuation.resume(returning: body(LeoIdleEventLoop()))
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// One short wait, drained within `turnWait` whether or not an event
    /// arrives. `handling` runs as the event's handling would, inside the
    /// same pool -- a window closed there goes when the turn ends.
    func turn(handling: () -> Void = {}) {
        autoreleasepool {
            if let event = NSApp.nextEvent(
                matching: .applicationDefined, until: Date(timeIntervalSinceNow: Self.turnWait), inMode: .default, dequeue: true
            ), !isStopEvent(event) {
                NSApp.sendEvent(event)
            }
            handling()
        }
    }

    /// Turns until `condition` holds, so the main-queue work queued so far
    /// runs. False if it still doesn't when `timeout` passes.
    func turns(until condition: () -> Bool, timeout: Duration) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if autoreleasepool(invoking: condition) { return true }
            turn()
        }
        return autoreleasepool(invoking: condition)
    }

    /// Waits as an idle app does, each wait ending only when an event
    /// arrives -- here, a `LeoEventLoop` wake posted for window
    /// `windowNumber`; any other application-defined event is dropped
    /// within the same wait. True once `isDone` holds -- after a wait was
    /// drained, or during one, with nothing left for a drain to let go of.
    /// False if it still doesn't hold when `timeout` passes, judged before
    /// the wait then ended is drained.
    func idle(
        until isDone: @escaping @MainActor () -> Bool, wakingFor windowNumber: Int, timeout: Duration
    ) -> Bool {
        let outcome = IdleOutcome()
        let check = Timer(timeInterval: Self.idleCheckInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard outcome.isDone == nil, isDone() else { return }
                outcome.isDone = true
                Self.postStopEvent()
            }
        }
        let watchdog = Timer(timeInterval: Self.seconds(timeout), repeats: false) { _ in
            MainActor.assumeIsolated {
                guard outcome.isDone == nil else { return }
                outcome.isDone = isDone()
                Self.postStopEvent()
            }
        }
        [check, watchdog].forEach { RunLoop.main.add($0, forMode: .common) }
        defer { [check, watchdog].forEach { $0.invalidate() } }

        while outcome.isDone == nil {
            if autoreleasepool(invoking: isDone) { return true }
            autoreleasepool {
                while let event = NSApp.nextEvent(
                    matching: .applicationDefined, until: .distantFuture, inMode: .default, dequeue: true
                ), !isStopEvent(event) {
                    guard isWake(event, for: windowNumber) else { continue }
                    NSApp.sendEvent(event)
                    return
                }
            }
        }
        return outcome.isDone ?? false
    }

    /// Waits as an idle app does for `duration`, each application-defined
    /// event ending a wait of its own, and returns how long after the start
    /// each `LeoEventLoop` wake posted for window `windowNumber` arrived.
    /// Other application-defined events are dropped.
    func wakes(for windowNumber: Int, during duration: Duration) -> [Duration] {
        let start = ContinuousClock.now
        let deadline = start + duration
        var arrivals: [Duration] = []
        while ContinuousClock.now < deadline {
            autoreleasepool {
                let until = Date(timeIntervalSinceNow: Self.seconds(deadline - .now))
                guard let event = NSApp.nextEvent(
                    matching: .applicationDefined, until: until, inMode: .default, dequeue: true
                ), isWake(event, for: windowNumber) else { return }
                arrivals.append(.now - start)
            }
        }
        return arrivals
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    @MainActor private final class IdleOutcome {
        var isDone: Bool?
    }

    private func isStopEvent(_ event: NSEvent) -> Bool {
        event.type == .applicationDefined && event.subtype.rawValue == Self.stopSubtype
    }

    private func isWake(_ event: NSEvent, for windowNumber: Int) -> Bool {
        event.type == .applicationDefined && event.subtype.rawValue == LeoEventLoop.wakeEventSubtype
            && event.data1 == windowNumber
    }

    private static func postStopEvent() {
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: stopSubtype, data1: 0, data2: 0
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
