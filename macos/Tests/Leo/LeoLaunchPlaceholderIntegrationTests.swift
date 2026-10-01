import AppKit
import Testing

@testable import Ghostty

/// B-085 against real windows: `TerminalController.newWindow` (a script's
/// `make new window`, the New Terminal intent, New Window Here) and
/// `newTab` (an opened folder; a window of its own with tabs off) hand the
/// window they open to the app's `LeoLaunchPlaceholder`, and an untouched
/// launch window gives way to it on its spot. Needs the app's real
/// `Ghostty.App`, so the suite is skipped (and says so) without it.
///
/// Unlike most integration suites here the windows are shown: the
/// replacement is about what is on screen. Each test adopts its own launch
/// window (the test host's is never adopted), closes every window it
/// opened even when a requirement fails, and leaves the tracker holding
/// nothing and the cascade point where it found it; undo registration is
/// off while windows open, so the app's undo stack is left alone.
/// Requested windows run the default shell, never an agent.
@MainActor @Suite(
    .serialized,
    .enabled("needs the app's Ghostty.App") { await MainActor.run { hasLiveGhosttyApp } },
    LeoCascadePointRestoringTrait()
)
struct LeoLaunchPlaceholderIntegrationTests {
    private static var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// How long a step may take to settle on a loaded host.
    private static let settleTimeout: Duration = .seconds(30)

    /// The app, with the real `Ghostty.App` the suite's trait checked for.
    private func liveApp() throws -> AppDelegate {
        try #require(Self.app)
    }

    /// What one main-queue turn can change about `controllers` and the
    /// tracker: whether it settled is whether a turn changed none of it.
    private struct Snapshot: Equatable {
        let windows: [WindowState]
        let launchWindow: ObjectIdentifier?

        struct WindowState: Equatable {
            let isVisible: Bool
            let isShown: Bool
            let frame: NSRect?
        }
    }

    private func snapshot(_ app: AppDelegate, _ controllers: [TerminalController]) -> Snapshot {
        Snapshot(
            windows: controllers.map {
                .init(isVisible: $0.window?.isVisible == true, isShown: $0.isLeoWindowShown, frame: $0.window?.frame)
            },
            launchWindow: app.leoLaunchPlaceholder.launchWindow.map(ObjectIdentifier.init)
        )
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// Waits until no presentation `controllers` queued is still pending
    /// (each ran, or was cancelled by a close) and a whole main-queue turn
    /// after that changed nothing about them: by then whatever those
    /// presentations queued -- the cascade, the tracker's close -- has run
    /// too. False if that never happens within the timeout.
    private func settle(_ app: AppDelegate, _ controllers: TerminalController...) async -> Bool {
        let deadline = ContinuousClock.now + Self.settleTimeout
        var previous: Snapshot?
        while ContinuousClock.now < deadline {
            await nextMainQueueTurn()
            let current = snapshot(app, controllers)
            if !controllers.contains(where: \.leoIsAwaitingPresentation), current == previous { return true }
            previous = current
        }
        return false
    }

    private func withoutUndo<T>(_ app: AppDelegate, _ body: () throws -> T) rethrows -> T {
        app.undoManager.disableUndoRegistration()
        defer { app.undoManager.enableUndoRegistration() }
        return try body()
    }

    /// A start window as the launch opens it -- shown -- handed to the
    /// app's tracker. Closed again if it never settles.
    private func makeLaunchWindow(_ app: AppDelegate) async throws -> TerminalController {
        let launch = withoutUndo(app) { TerminalController.leoNewPlaceholderWindow(app.ghostty) }
        let isSettled = await settle(app, launch)
        if !isSettled { close(launch) }
        try #require(isSettled, "the launch window's presentation never settled")
        app.leoLaunchPlaceholder.adopt(launch)
        return launch
    }

    private func topLeft(_ controller: TerminalController) -> NSPoint? {
        controller.window.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) }
    }

    private func close(_ controllers: TerminalController?...) {
        controllers.compactMap { $0?.window }.filter(\.isVisible).forEach { $0.close() }
    }

    /// Records the window's `willClose`.
    @MainActor private final class CloseFlag {
        private(set) var isClosed = false
        private var observer: NSObjectProtocol?

        init(_ window: NSWindow?) {
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: nil
            ) { [weak self] _ in MainActor.assumeIsolated { self?.isClosed = true } }
        }

        func stop() {
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
        }
    }

    /// Of `launch` and `requested`, the ones on screen.
    private func shown(_ controllers: TerminalController...) -> [ObjectIdentifier] {
        controllers.filter { $0.window?.isVisible == true }.map(ObjectIdentifier.init)
    }

    /// A text field (the sidebar's search, say) is being edited: its field
    /// editor is the window's first responder.
    private func isEditingText(_ controller: TerminalController) -> Bool {
        (controller.window?.firstResponder as? NSText)?.isFieldEditor == true
    }

    @Test func aNewWindowReplacesTheLaunchWindowOnItsSpot() async throws {
        let app = try liveApp()
        let launch = try await makeLaunchWindow(app)
        defer { close(launch) }
        let closed = CloseFlag(launch.window)
        defer { closed.stop() }
        let spot = try #require(topLeft(launch))

        let requested = withoutUndo(app) { TerminalController.newWindow(app.ghostty) }
        defer { close(requested) }
        try #require(await settle(app, launch, requested), "the windows never settled")

        #expect(closed.isClosed)
        #expect(requested.window?.isVisible == true)
        #expect(shown(launch, requested) == [ObjectIdentifier(requested)])
        #expect(topLeft(requested) == spot)
        #expect(app.leoLaunchPlaceholder.launchWindow == nil)
        // B-093: the window taking the launch window's place starts in its
        // content, never the sidebar's search field (D-173; ⌥⌘F gets there).
        #expect(!isEditingText(requested), "first responder: \(String(describing: requested.window?.firstResponder))")
    }

    @Test func aNewTabWindowReplacesTheLaunchWindowOnItsSpot() async throws {
        let app = try liveApp()
        let launch = try await makeLaunchWindow(app)
        defer { close(launch) }
        let closed = CloseFlag(launch.window)
        defer { closed.stop() }
        let spot = try #require(topLeft(launch))

        let opened = withoutUndo(app) { TerminalController.newTab(app.ghostty, from: launch.window) }
        defer { close(opened) }
        let requested = try #require(opened)
        try #require(await settle(app, launch, requested), "the windows never settled")

        #expect(closed.isClosed)
        #expect(requested.window?.isVisible == true)
        #expect(shown(launch, requested) == [ObjectIdentifier(requested)])
        #expect(topLeft(requested) == spot)
        #expect(app.leoLaunchPlaceholder.launchWindow == nil)
    }

    /// The review's P1 case: the requested window never shows (its
    /// presentation is cancelled when it closes first), so Leo must not
    /// end up with no window at all.
    @Test func aRequestedWindowClosedBeforeItShowsLeavesTheLaunchWindow() async throws {
        let app = try liveApp()
        let launch = try await makeLaunchWindow(app)
        defer { close(launch) }
        let closed = CloseFlag(launch.window)
        defer { closed.stop() }

        let requested = withoutUndo(app) { TerminalController.newWindow(app.ghostty) }
        defer { close(requested) }
        requested.window?.close()
        try #require(await settle(app, launch, requested), "the windows never settled")

        #expect(!closed.isClosed)
        #expect(launch.window?.isVisible == true)
    }

    /// `LeoCommandLauncher.openWindow(in:)` from the start screen's own
    /// buttons (Start daemon, ssh) names the launch window as the parent.
    @Test func aWindowTheLaunchWindowOpensLeavesIt() async throws {
        let app = try liveApp()
        let launch = try await makeLaunchWindow(app)
        defer { close(launch) }
        let closed = CloseFlag(launch.window)
        defer { closed.stop() }

        let requested = withoutUndo(app) { TerminalController.newWindow(app.ghostty, withParent: launch.window) }
        defer { close(requested) }
        try #require(await settle(app, launch, requested), "the windows never settled")

        #expect(!closed.isClosed)
        #expect(shown(launch, requested).count == 2)
        #expect(app.leoLaunchPlaceholder.launchWindow == nil)
    }

    @Test func aLaunchWindowShowingASheetStays() async throws {
        let app = try liveApp()
        let launch = try await makeLaunchWindow(app)
        defer { close(launch) }
        let window = try #require(launch.window)
        let closed = CloseFlag(window)
        defer { closed.stop() }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.beginSheet(sheet, completionHandler: nil)
        defer { window.endSheet(sheet) }

        let requested = withoutUndo(app) { TerminalController.newWindow(app.ghostty) }
        defer { close(requested) }
        try #require(await settle(app, launch, requested), "the windows never settled")

        #expect(!closed.isClosed)
    }

    /// B-093: the launch window reads shown once presented and stops the
    /// moment it closes, which the queued close checks before closing it.
    @Test func aClosedLaunchWindowNoLongerReadsShown() async throws {
        let app = try liveApp()
        let launch = try await makeLaunchWindow(app)
        defer { close(launch) }
        let window = try #require(launch.window)
        let shownOnceOpen = launch.isLeoWindowShown

        window.close()

        #expect(shownOnceOpen)
        #expect(!launch.isLeoWindowShown)
    }

    /// Closed without a key or mouse press (a script's `close window 1`):
    /// the tracker stops watching it.
    @Test func aLaunchWindowClosedOnItsOwnIsForgotten() async throws {
        let app = try liveApp()
        let launch = try await makeLaunchWindow(app)
        defer { close(launch) }

        launch.window?.close()

        #expect(app.leoLaunchPlaceholder.launchWindow == nil)
    }

    /// The launch window opens as the start screen alone, as a foreground
    /// launch leaves it: no agent palette (which, with nothing to take key
    /// status from it, stayed up over a background launch's window). The
    /// test host never hands it to the tracker.
    @Test func theLaunchWindowOpensWithoutThePaletteAndTheTestHostKeepsIt() async throws {
        let app = try liveApp()

        let launch = withoutUndo(app) { app.leoOpenLaunchWindow() }
        defer { close(launch) }
        let session = try #require(launch.leoSession)

        #expect(!session.isPickerPresented)
        #expect(app.leoLaunchPlaceholder.launchWindow !== launch)
        try #require(await settle(app, launch), "the windows never settled")
        #expect(launch.window?.isVisible == true)
    }
}

/// The app has a real `Ghostty.App` to make surfaces with. Outside the
/// suite: its own `@Suite` attribute can't name the suite.
@MainActor private var hasLiveGhosttyApp: Bool {
    (NSApp.delegate as? AppDelegate)?.ghostty.app != nil
}

/// Puts `TerminalController`'s cascade point back after each test: the
/// tests above move it (a replaced launch window holds its spot there),
/// and the next window anything opens would cascade from it. Recursive,
/// so each test gets its own scope; that makes it a `TestTrait` too, which
/// Swift Testing requires of a trait it applies to test functions (the
/// host traps at discovery without it).
struct LeoCascadePointRestoringTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable @concurrent () async throws -> Void
    ) async throws {
        let saved = await MainActor.run { TerminalController.leoCascadePoint }
        do {
            try await function()
        } catch {
            await MainActor.run { TerminalController.leoCascadePoint = saved }
            throw error
        }
        await MainActor.run { TerminalController.leoCascadePoint = saved }
    }
}
