import AppKit
import Testing

@testable import Ghostty

/// B-447: `Ghostty.FocusMover` retries a focus move until its view joins a
/// window. Within one window the newest move that has landed wins: an older
/// move still retrying never takes focus back from it.
///
/// Never-shown windows and plain views; a recording scheduler runs each
/// queued attempt only when the test says so. No timers, no sleeps.
@MainActor struct FocusMoveOrderTests {
    /// Records each queued attempt instead of putting it on the main queue.
    private final class RecordingScheduler: Ghostty.FocusMoveScheduler {
        private var queued: [(delay: TimeInterval?, work: () -> Void)] = []
        /// Every delay ever asked for, in order (`nil`: no delay).
        private(set) var delays: [TimeInterval?] = []

        var isEmpty: Bool { queued.isEmpty }

        func schedule(after delay: TimeInterval?, _ work: @escaping () -> Void) {
            queued.append((delay, work))
            delays.append(delay)
        }

        /// Runs the oldest queued attempt that has no delay (`delayed:
        /// false`) or that is a timed retry (`delayed: true`), as the main
        /// queue runs an `async` before a timer that is not yet due.
        func runFirst(delayed: Bool) throws {
            let index = try #require(queued.firstIndex { ($0.delay != nil) == delayed }, "nothing queued")
            queued.remove(at: index).work()
        }

        func runAll() {
            while !queued.isEmpty { queued.removeFirst().work() }
        }
    }

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private let scheduler = RecordingScheduler()
    private let mover: Ghostty.FocusMover

    init() {
        mover = Ghostty.FocusMover(scheduler: scheduler)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// The report (LeoRowSplitIntoShellTests.swift:94): A's view isn't in
    /// the window yet, so A retries; B, asked later, lands; A's view joins
    /// the window, as the display cycle puts it there, and A's retry runs.
    @Test func anOlderMoveRetryingForAWindowNeverTakesFocusBackFromANewerOne() throws {
        let window = makeWindow()
        let a = FocusableView(), b = FocusableView()
        try #require(window.contentView).addSubview(b)
        mover.move(to: a)
        try scheduler.runFirst(delayed: false)
        mover.move(to: b)
        try scheduler.runFirst(delayed: false)
        try #require(window.firstResponder === b, "B landed")

        try #require(window.contentView).addSubview(a)
        try scheduler.runFirst(delayed: true)

        #expect(window.firstResponder === b, "the newer move keeps focus")
    }

    /// With nothing newer landed, a retry still lands once its view joins
    /// the window (B-204 and the integration fixtures rely on it).
    @Test func aRetryStillLandsWhenNothingNewerHasLanded() throws {
        let window = makeWindow()
        let a = FocusableView()
        mover.move(to: a)
        try scheduler.runFirst(delayed: false)
        try #require(window.contentView).addSubview(a)

        try scheduler.runFirst(delayed: true)

        #expect(window.firstResponder === a)
    }

    /// A newer move landing in another window leaves this window's retry
    /// alone: windows are ordered apart.
    @Test func aNewerMoveInAnotherWindowDoesNotCancelThisWindowsRetry() throws {
        let first = makeWindow(), second = makeWindow()
        let a = FocusableView(), b = FocusableView()
        try #require(second.contentView).addSubview(b)
        mover.move(to: a)
        try scheduler.runFirst(delayed: false)
        mover.move(to: b)
        try scheduler.runFirst(delayed: false)
        try #require(second.firstResponder === b)

        try #require(first.contentView).addSubview(a)
        try scheduler.runFirst(delayed: true)

        #expect(first.firstResponder === a)
        #expect(second.firstResponder === b)
    }

    /// A view that never gets a window: retries at 50, 100, 200 and 400 ms,
    /// then the move gives up (LeoContentFocusTests' 0.8 s drain counts on
    /// it).
    @Test func retriesBackOffFromFiftyMillisecondsAndGiveUpAfterFour() {
        let windowless = FocusableView()
        mover.move(to: windowless)

        withExtendedLifetime(windowless) { scheduler.runAll() }

        #expect(scheduler.delays == [nil, 0.05, 0.1, 0.2, 0.4])
        #expect(scheduler.isEmpty)
    }
}
