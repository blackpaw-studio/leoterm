import AppKit
import Testing

@testable import Ghostty

/// B-143: when `LeoEventLoop.wakeUntilFreed` stops waking the event loop
/// for a closed window: once it is shown again, once the limit passes, and
/// once it and its window-server window are gone -- the wake is bounded and
/// ends when its work is done, never a loop left running (P5). (That it
/// wakes it until it is gone, the release tests show.)
///
/// Each test closes a plain window, keeping it alive unless freeing it is
/// the stop condition under test, and counts the wakes posted for that
/// window inside `LeoIdleEventLoop`, with a short interval and limit.
@MainActor @Suite(.serialized)
struct LeoEventLoopWakeTests {
    /// The tests' wake interval.
    private static let interval: TimeInterval = 0.05

    /// How long a test watches the wakes of a closed window.
    private static let closedWatch: Duration = .milliseconds(300)

    /// How late a wake may arrive on a loaded host: the tick's timer
    /// tolerance, and the event's trip through the queue.
    private static let slack: Duration = .milliseconds(300)

    private func makeShownWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    @Test func aClosedWindowShownAgainIsNoLongerWoken() async {
        let window = makeShownWindow()
        defer { window.close() }
        let limit: TimeInterval = 5

        let (whileClosed, afterShown) = await LeoIdleEventLoop.run { loop in
            let number = window.windowNumber
            window.close()
            LeoEventLoop.wakeUntilFreed(window, number: number, every: Self.interval, for: limit)
            let whileClosed = loop.wakes(for: number, during: Self.closedWatch)
            window.orderFront(nil)
            let afterShown = loop.wakes(for: number, during: Self.closedWatch + Self.slack * 2)
            return (whileClosed, afterShown)
        }

        #expect(!whileClosed.isEmpty, "the closed window's loop was never woken")
        // One wake may already be queued when it is shown; none after the next tick.
        let firstTick: Duration = .seconds(Self.interval) + Self.slack
        #expect(afterShown.filter { $0 > firstTick }.isEmpty, "woken after shown again: \(afterShown)")
    }

    @Test func aClosedWindowIsWokenOnlyUntilTheLimit() async {
        let window = makeShownWindow()
        defer { window.close() }
        let limit: TimeInterval = 0.5

        let arrivals = await LeoIdleEventLoop.run { loop in
            let number = window.windowNumber
            window.close()
            LeoEventLoop.wakeUntilFreed(window, number: number, every: Self.interval, for: limit)
            return loop.wakes(for: number, during: .seconds(limit) + Self.closedWatch + Self.slack * 2)
        }

        #expect(arrivals.count > 1, "the closed window's loop was barely woken: \(arrivals)")
        #expect(
            arrivals.allSatisfy { $0 < .seconds(limit) + Self.slack },
            "woken past the \(limit) s limit: \(arrivals)"
        )
    }

    /// The P5 guard: the wake stops once the window it was started for is
    /// freed and the window server no longer lists it, long before the
    /// limit. The window is opened, closed and let go of inside the loop, so
    /// only its wakes' drains free it.
    @Test func aFreedWindowIsNoLongerWoken() async {
        let limit: TimeInterval = 5
        let freeTimeout: Duration = .seconds(3)

        let (number, isFreed, afterFreed) = await LeoIdleEventLoop.run { loop -> (Int, Bool, [Duration]) in
            var window: NSWindow? = autoreleasepool { makeShownWindow() }
            weak var traced = window
            let number = autoreleasepool { window?.windowNumber ?? 0 }
            loop.turn {
                guard let closing = window else { return }
                closing.close()
                LeoEventLoop.wakeUntilFreed(closing, number: number, every: Self.interval, for: limit)
                window = nil
            }
            let isFreed = loop.idle(
                until: { traced == nil && !LeoEventLoop.windowServerLists(number) },
                wakingFor: number, timeout: freeTimeout
            )
            let afterFreed = loop.wakes(for: number, during: Self.closedWatch + Self.slack * 2)
            return (number, isFreed, afterFreed)
        }

        #expect(isFreed, "the closed window #\(number) was not freed within \(freeTimeout)")
        // One wake may already be queued when it goes; none after the next tick.
        let firstTick: Duration = .seconds(Self.interval) + Self.slack
        #expect(afterFreed.filter { $0 > firstTick }.isEmpty, "woken after freed: \(afterFreed)")
    }
}
