import AppKit
import CoreGraphics
import Testing

@testable import Ghostty

/// B-143: a launch window that gave way to a requested window (B-085) is
/// let go of as soon as it closes -- its controller and its window freed,
/// gone from `NSApp.windows` and the window server's list -- even when Leo
/// then sits idle. B-093's verify found it still listed, off screen, after
/// the replacement.
///
/// Nothing of Leo's kept it for good. AppKit's event loop keeps every
/// window in the autorelease pool of the wait in progress, drained only
/// when the next event arrives (see `LeoIdleEventLoop`), and a closed
/// window's last owner went during such a wait. Its controller goes a
/// run-loop pass after the close (AppKit's delayed constraint pass holds
/// the sidebar split's hosting views, whose SwiftUI graph holds the
/// controller); a replaced launch window closes mid-wait, from the
/// tracker's main-queue turn; and a New Tab opened from it held it in its
/// undo action (redo opens the tab from it again) until that expired, from
/// a timer -- it now holds it weakly. Idle, the window stayed until the
/// user's next key press or click. The control shows the same held for
/// any start-screen window the user closed.
///
/// Each test runs inside `LeoIdleEventLoop`, which waits as the idle app
/// does, and keeps only weak references to the window and its controller
/// and the window's number (which outlives both), so nothing of the test's
/// keeps them alive. A window counts as let go of once it, its controller
/// and its window-server window are all gone: AppKit hands a freed
/// window's window-server window to the wait in progress too, and a test
/// that stopped waiting at the window would leave that to the test host's
/// loop, which never drains. A replacement test adopts its own launch
/// window (the test host's is never adopted). Each test opens windows with
/// undo registration off -- but for the undo test, which drops the action
/// it registered whatever happens -- closes every window it opened, and
/// leaves the cascade point where it found it. Requested windows run the
/// default shell, never an agent.
/// Needs the app's real `Ghostty.App`, so the suite is skipped (and says
/// so) without it.
@MainActor @Suite(
    .serialized,
    .enabled("needs the app's Ghostty.App") { await MainActor.run { hasLiveGhosttyApp } },
    LeoCascadePointRestoringTrait()
)
struct LeoReplacedLaunchWindowReleaseTests {
    private static var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// How long a window may take to present on a loaded host.
    private static let presentationTimeout: Duration = .seconds(30)

    /// How long a closed window may take to be let go of on a loaded host.
    private static let releaseTimeout: Duration = .seconds(30)

    /// How much sooner than its undo action can expire the undo test's
    /// launch window must be let go of: the action's timer started a
    /// moment before the test's clock, and the wake after it may come
    /// within a wake interval.
    private static let undoExpiryMargin: Duration = .seconds(1)

    /// The shortest undo timeout the undo test can tell apart from a
    /// release: a window is freed within a wake interval of its close.
    private static let minimumUndoTimeout: Duration = .seconds(2)

    private func liveApp() throws -> AppDelegate {
        try #require(Self.app)
    }

    private func withoutUndo<T>(_ app: AppDelegate, _ body: () throws -> T) rethrows -> T {
        app.undoManager.disableUndoRegistration()
        defer { app.undoManager.enableUndoRegistration() }
        return try body()
    }

    /// A window the test lets go of: weak references to it and its
    /// controller, and its window number.
    @MainActor private final class Trace {
        weak var controller: TerminalController?
        weak var window: NSWindow?
        let windowNumber: Int

        init(_ controller: TerminalController, window: NSWindow) {
            self.controller = controller
            self.window = window
            windowNumber = window.windowNumber
        }

        /// It, its controller and its window-server window are all gone.
        var isFreed: Bool {
            controller == nil && window == nil
                && !LeoReplacedLaunchWindowReleaseTests.serverWindowNumbers().contains(windowNumber)
        }

        /// Closes the window if it is still open (a test that failed early).
        func closeIfOpen() {
            autoreleasepool {
                guard let controller, !controller.leoWindowDidClose else { return }
                controller.window?.close()
            }
        }
    }

    /// The undo action the New Tab replacing a launch window registered.
    private struct UndoState {
        var timeout: Duration?
        var wasRegistered = false
        /// How long after the New Tab opened the launch window was let go
        /// of, if it was.
        var releasedAfter: Duration?
    }

    /// What a test found once its loop returned.
    private struct Outcome {
        /// Let go of while the app sat idle.
        let isReleasedWhileIdle: Bool
        /// The windows the test opened besides the traced one.
        let others: [TerminalController]
    }

    /// Inside `loop`: a start-screen window, presented and its cascade run.
    /// Only its trace leaves; nil (closing it) if it never presents.
    private func openStartScreenWindow(_ app: AppDelegate, in loop: LeoIdleEventLoop) -> Trace? {
        let controller = autoreleasepool { withoutUndo(app) { TerminalController.leoNewPlaceholderWindow(app.ghostty) } }
        let isPresented = loop.turns(
            until: { !controller.leoIsAwaitingPresentation && controller.window?.isVisible == true },
            timeout: Self.presentationTimeout
        )
        guard isPresented, let window = autoreleasepool(invoking: { controller.window }) else {
            autoreleasepool { controller.window?.close() }
            return nil
        }
        // The cascade its presentation queued.
        loop.turn()
        return Trace(controller, window: window)
    }

    /// Inside `loop`: a start-screen window, presented and handed to the
    /// app's tracker as the launch's own (as `makeLaunchWindow` in the
    /// integration suite does).
    private func openLaunchWindow(_ app: AppDelegate, in loop: LeoIdleEventLoop) -> Trace? {
        guard let trace = openStartScreenWindow(app, in: loop) else { return nil }
        autoreleasepool {
            guard let controller = trace.controller else { return }
            app.leoLaunchPlaceholder.adopt(controller)
        }
        return trace
    }

    /// The window-server windows this process owns, on screen or not.
    private static func serverWindowNumbers() -> Set<Int> {
        let pid = Int(getpid())
        let infos = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        return Set(infos.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int) == pid else { return nil }
            return info[kCGWindowNumber as String] as? Int
        })
    }

    /// What is left of `trace`'s window: empty once it is all gone.
    private func remains(of trace: Trace) -> [String] {
        autoreleasepool {
            [
                trace.controller != nil ? "its controller" : nil,
                trace.window != nil ? "its window" : nil,
                NSApp.windows.contains { $0.windowNumber == trace.windowNumber } ? "an NSApp.windows entry" : nil,
                Self.serverWindowNumbers().contains(trace.windowNumber) ? "a window-server window" : nil,
            ].compactMap { $0 }
        }
    }

    /// Opens a launch window inside the idle loop, has `request` open a
    /// window in its place (as an event's handling would: an Apple Event,
    /// an opened folder), then waits as the idle app does for the launch
    /// window to be let go of.
    private func replaceLaunchWindow(
        _ app: AppDelegate,
        request: @escaping @MainActor (Trace) -> TerminalController?
    ) async throws -> (Trace, Outcome) {
        let (trace, outcome) = await LeoIdleEventLoop.run { loop -> (Trace?, Outcome) in
            guard let launch = openLaunchWindow(app, in: loop) else { return (nil, Outcome(isReleasedWhileIdle: false, others: [])) }
            var requested: TerminalController?
            loop.turn { requested = withoutUndo(app) { request(launch) } }
            let isReleased = loop.idle(
                until: { launch.isFreed }, wakingFor: launch.windowNumber, timeout: Self.releaseTimeout
            )
            return (launch, Outcome(isReleasedWhileIdle: isReleased, others: requested.map { [$0] } ?? []))
        }
        let launch = try #require(trace, "the launch window never presented")
        return (launch, outcome)
    }

    /// Closes what a test opened, and drops any undo action it left.
    private func close(_ trace: Trace, _ outcome: Outcome) {
        trace.closeIfOpen()
        autoreleasepool {
            outcome.others.forEach { Self.app?.undoManager.removeAllActions(withTarget: $0) }
            outcome.others.filter { !$0.leoWindowDidClose }.compactMap(\.window).forEach { $0.close() }
        }
    }

    @Test func aReplacedLaunchWindowIsReleased() async throws {
        let app = try liveApp()

        let (launch, outcome) = try await replaceLaunchWindow(app) { _ in
            TerminalController.newWindow(app.ghostty)
        }
        defer { close(launch, outcome) }

        #expect(outcome.others.count == 1)
        #expect(outcome.isReleasedWhileIdle, "the replaced launch window #\(launch.windowNumber) waited for the next event")
        let left = remains(of: launch)
        #expect(left.isEmpty, "the replaced launch window #\(launch.windowNumber) lingers: \(left)")
    }

    @Test func aReplacedLaunchWindowGivingWayToANewTabIsReleased() async throws {
        let app = try liveApp()

        let (launch, outcome) = try await replaceLaunchWindow(app) { launch in
            TerminalController.newTab(app.ghostty, from: launch.window)
        }
        defer { close(launch, outcome) }

        #expect(outcome.others.count == 1)
        #expect(outcome.isReleasedWhileIdle, "the replaced launch window #\(launch.windowNumber) waited for the next event")
        let left = remains(of: launch)
        #expect(left.isEmpty, "the replaced launch window #\(launch.windowNumber) lingers: \(left)")
    }

    /// The release B-093's verify missed, through an opened folder: the
    /// New Tab replacing the launch window is undoable, and its action's
    /// redo opens the tab from the launch window again. The action must not
    /// keep the closed launch window: it is let go of while the action
    /// lasts, not when the action expires (undo timeout), from a timer,
    /// mid-wait -- which, with an undo timeout past the wake limit, would
    /// leave it to the user's next event.
    @Test func aReplacedLaunchWindowIsReleasedWhileItsReplacementsUndoActionLasts() async throws {
        let app = try liveApp()

        let (trace, undo, outcome) = await LeoIdleEventLoop.run { loop -> (Trace?, UndoState, Outcome) in
            guard let launch = openLaunchWindow(app, in: loop) else {
                return (nil, UndoState(), Outcome(isReleasedWhileIdle: false, others: []))
            }
            var requested: TerminalController?
            var requestedAt = ContinuousClock.now
            loop.turn {
                requestedAt = .now
                requested = TerminalController.newTab(app.ghostty, from: launch.window)
            }
            let replacement = requested
            let wasRegistered = autoreleasepool { app.undoManager.undoActionName == "New Tab" }
            let isReleased = loop.idle(
                until: { launch.isFreed }, wakingFor: launch.windowNumber, timeout: Self.releaseTimeout
            )
            let undo = UndoState(
                timeout: replacement?.undoExpiration,
                wasRegistered: wasRegistered,
                releasedAfter: isReleased ? ContinuousClock.now - requestedAt : nil
            )
            return (launch, undo, Outcome(isReleasedWhileIdle: isReleased, others: replacement.map { [$0] } ?? []))
        }
        let launch = try #require(trace, "the launch window never presented")
        defer { close(launch, outcome) }

        try #require(undo.wasRegistered, "the New Tab replacing the launch window registered no undo action")
        let timeout = try #require(undo.timeout)
        try #require(timeout >= Self.minimumUndoTimeout, "an undo timeout of \(timeout) can't be told from a release")
        #expect(outcome.others.count == 1)
        #expect(outcome.isReleasedWhileIdle, "the replaced launch window #\(launch.windowNumber) waited for the next event")
        let releasedAfter = try #require(undo.releasedAfter)
        #expect(
            releasedAfter < timeout - Self.undoExpiryMargin,
            "the replaced launch window #\(launch.windowNumber) waited \(releasedAfter) for its undo action to expire"
        )
        let left = remains(of: launch)
        #expect(left.isEmpty, "the replaced launch window #\(launch.windowNumber) lingers: \(left)")
    }

    /// The control: a start-screen window nothing replaced, closed as the
    /// user's ⌘W or a script's `close window 1` closes it -- while an
    /// event is handled -- is let go of without waiting for another event.
    @Test func aClosedStartScreenWindowIsReleased() async throws {
        let app = try liveApp()

        let (trace, isReleased) = await LeoIdleEventLoop.run { loop -> (Trace?, Bool) in
            guard let start = openStartScreenWindow(app, in: loop) else { return (nil, false) }
            loop.turn { start.window?.close() }
            let isReleased = loop.idle(
                until: { start.isFreed }, wakingFor: start.windowNumber, timeout: Self.releaseTimeout
            )
            return (start, isReleased)
        }
        let start = try #require(trace, "the start-screen window never presented")
        defer { start.closeIfOpen() }

        #expect(isReleased, "the closed start-screen window #\(start.windowNumber) waited for the next event")
        let left = remains(of: start)
        #expect(left.isEmpty, "the closed start-screen window #\(start.windowNumber) lingers: \(left)")
    }
}

/// The app has a real `Ghostty.App` to make surfaces with. Outside the
/// suite: its own `@Suite` attribute can't name the suite.
@MainActor private var hasLiveGhosttyApp: Bool {
    (NSApp.delegate as? AppDelegate)?.ghostty.app != nil
}
