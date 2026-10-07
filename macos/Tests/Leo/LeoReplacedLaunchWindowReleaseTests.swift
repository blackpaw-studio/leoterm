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
/// window's last owner, its controller, went during such a wait: a
/// run-loop pass after the close (AppKit's delayed constraint pass holds
/// the sidebar split's hosting views, whose SwiftUI graph holds the
/// controller), and for a replaced launch window after a close that itself
/// ran mid-wait, from the tracker's main-queue turn. Idle, the window
/// stayed until the user's next key press or click. The control shows the
/// same held for any start-screen window the user closed.
///
/// Each test runs inside `LeoIdleEventLoop`, which waits as the idle app
/// does, and keeps only weak references to the window and its controller
/// and the window's number (which outlives both), so nothing of the test's
/// keeps them alive. A replacement test adopts its own launch window (the
/// test host's is never adopted). Each test opens windows with undo
/// registration off, closes every window it opened, and leaves the
/// cascade point where it found it. Requested windows run the default
/// shell, never an agent.
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

    /// How long the window server may take to drop a freed window's own.
    private static let serverReleaseTimeout: Duration = .seconds(5)

    private func liveApp() throws -> AppDelegate {
        try #require(Self.app)
    }

    private func withoutUndo<T>(_ app: AppDelegate, _ body: () throws -> T) rethrows -> T {
        app.undoManager.disableUndoRegistration()
        defer { app.undoManager.enableUndoRegistration() }
        return try body()
    }

    /// A window the test lets go of: weak references to it and its
    /// controller, and its window-server number.
    @MainActor private final class Trace {
        weak var controller: TerminalController?
        weak var window: NSWindow?
        let windowNumber: Int

        init(_ controller: TerminalController, window: NSWindow) {
            self.controller = controller
            self.window = window
            windowNumber = window.windowNumber
        }

        var isFreed: Bool { controller == nil && window == nil }

        /// Closes the window if it is still open (a test that failed early).
        func closeIfOpen() {
            autoreleasepool {
                guard let controller, !controller.leoWindowDidClose else { return }
                controller.window?.close()
            }
        }
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

    /// What is left of `trace`'s window: empty once it is all gone. The
    /// window server may drop its window a moment after the window is
    /// freed, so that part is polled.
    private func remains(of trace: Trace) async -> [String] {
        var left = autoreleasepool {
            [
                trace.controller != nil ? "its controller" : nil,
                trace.window != nil ? "its window" : nil,
                NSApp.windows.contains { $0.windowNumber == trace.windowNumber } ? "an NSApp.windows entry" : nil,
            ].compactMap { $0 }
        }
        let deadline = ContinuousClock.now + Self.serverReleaseTimeout
        while Self.serverWindowNumbers().contains(trace.windowNumber) {
            guard ContinuousClock.now < deadline else {
                left.append("a window-server window")
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return left
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
            let isReleased = loop.idle(until: { launch.isFreed }, timeout: Self.releaseTimeout)
            return (launch, Outcome(isReleasedWhileIdle: isReleased, others: requested.map { [$0] } ?? []))
        }
        let launch = try #require(trace, "the launch window never presented")
        return (launch, outcome)
    }

    /// Closes what a test opened.
    private func close(_ trace: Trace, _ outcome: Outcome) {
        trace.closeIfOpen()
        autoreleasepool {
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
        let left = await remains(of: launch)
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
        let left = await remains(of: launch)
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
            return (start, loop.idle(until: { start.isFreed }, timeout: Self.releaseTimeout))
        }
        let start = try #require(trace, "the start-screen window never presented")
        defer { start.closeIfOpen() }

        #expect(isReleased, "the closed start-screen window #\(start.windowNumber) waited for the next event")
        let left = await remains(of: start)
        #expect(left.isEmpty, "the closed start-screen window #\(start.windowNumber) lingers: \(left)")
    }
}

/// The app has a real `Ghostty.App` to make surfaces with. Outside the
/// suite: its own `@Suite` attribute can't name the suite.
@MainActor private var hasLiveGhosttyApp: Bool {
    (NSApp.delegate as? AppDelegate)?.ghostty.app != nil
}
