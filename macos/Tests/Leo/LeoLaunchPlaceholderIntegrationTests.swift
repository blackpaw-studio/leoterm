import AppKit
import Testing

@testable import Ghostty

/// B-085 against real windows: `TerminalController.newWindow` (a script's
/// `make new window`, the New Terminal intent, New Window Here) and
/// `newTab` (an opened folder; a window of its own with tabs off) hand the
/// window they open to the app's `LeoLaunchPlaceholder`, and an untouched
/// launch window gives way to it on its spot. Needs the app's real
/// `Ghostty.App`, so these bail out (rather than fail) without it.
///
/// Unlike most integration suites here the windows are shown: the
/// replacement is about what is on screen. Each test adopts its own launch
/// window (the test host's is never adopted) and leaves the tracker holding
/// nothing; undo registration is off while windows open, so the app's undo
/// stack is left alone. Requested windows run the default shell, never an
/// agent.
@MainActor @Suite(.serialized) struct LeoLaunchPlaceholderIntegrationTests {
    private static var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// The app, when it has a real `Ghostty.App` to make surfaces with.
    private func liveApp() -> AppDelegate? {
        guard let app = Self.app, app.ghostty.app != nil else { return nil }
        return app
    }

    /// Enough main-queue turns for a presentation, the cascade `newWindow`
    /// queues from it, and the tracker's close.
    private func drainMainQueue() async {
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func withoutUndo<T>(_ app: AppDelegate, _ body: () -> T) -> T {
        app.undoManager.disableUndoRegistration()
        defer { app.undoManager.enableUndoRegistration() }
        return body()
    }

    /// A start window as the launch opens it -- shown -- handed to the
    /// app's tracker.
    private func makeLaunchWindow(_ app: AppDelegate) async -> TerminalController {
        let launch = withoutUndo(app) { TerminalController.leoNewPlaceholderWindow(app.ghostty) }
        await drainMainQueue()
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
        guard let app = liveApp() else { return }
        let launch = await makeLaunchWindow(app)
        let closed = CloseFlag(launch.window)
        defer { closed.stop() }
        let spot = try #require(topLeft(launch))

        let requested = withoutUndo(app) { TerminalController.newWindow(app.ghostty) }
        defer { close(requested, launch) }
        await drainMainQueue()

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
        guard let app = liveApp() else { return }
        let launch = await makeLaunchWindow(app)
        let closed = CloseFlag(launch.window)
        defer { closed.stop() }
        let spot = try #require(topLeft(launch))

        let requested = try #require(withoutUndo(app) { TerminalController.newTab(app.ghostty, from: launch.window) })
        defer { close(requested, launch) }
        await drainMainQueue()

        #expect(closed.isClosed)
        #expect(requested.window?.isVisible == true)
        #expect(shown(launch, requested) == [ObjectIdentifier(requested)])
        #expect(topLeft(requested) == spot)
    }

    /// The review's P1 case: the requested window never shows (its
    /// presentation is cancelled when it closes first), so Leo must not
    /// end up with no window at all.
    @Test func aRequestedWindowClosedBeforeItShowsLeavesTheLaunchWindow() async {
        guard let app = liveApp() else { return }
        let launch = await makeLaunchWindow(app)
        let closed = CloseFlag(launch.window)
        defer { closed.stop() }

        let requested = withoutUndo(app) { TerminalController.newWindow(app.ghostty) }
        requested.window?.close()
        defer { close(requested, launch) }
        await drainMainQueue()

        #expect(!closed.isClosed)
        #expect(launch.window?.isVisible == true)
    }

    /// `LeoCommandLauncher.openWindow(in:)` from the start screen's own
    /// buttons (Start daemon, ssh) names the launch window as the parent.
    @Test func aWindowTheLaunchWindowOpensLeavesIt() async {
        guard let app = liveApp() else { return }
        let launch = await makeLaunchWindow(app)
        let closed = CloseFlag(launch.window)
        defer { closed.stop() }

        let requested = withoutUndo(app) { TerminalController.newWindow(app.ghostty, withParent: launch.window) }
        defer { close(requested, launch) }
        await drainMainQueue()

        #expect(!closed.isClosed)
        #expect(shown(launch, requested).count == 2)
        #expect(app.leoLaunchPlaceholder.launchWindow == nil)
    }

    @Test func aLaunchWindowShowingASheetStays() async throws {
        guard let app = liveApp() else { return }
        let launch = await makeLaunchWindow(app)
        let window = try #require(launch.window)
        let closed = CloseFlag(window)
        defer { closed.stop() }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.beginSheet(sheet, completionHandler: nil)

        let requested = withoutUndo(app) { TerminalController.newWindow(app.ghostty) }
        defer {
            window.endSheet(sheet)
            close(requested, launch)
        }
        await drainMainQueue()

        #expect(!closed.isClosed)
    }

    /// B-093: the launch window reads shown once presented and stops the
    /// moment it closes, which the queued close checks before closing it.
    @Test func aClosedLaunchWindowNoLongerReadsShown() async throws {
        guard let app = liveApp() else { return }
        let launch = await makeLaunchWindow(app)
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
        guard let app = liveApp() else { return }
        let launch = await makeLaunchWindow(app)
        defer { close(launch) }

        launch.window?.close()

        #expect(app.leoLaunchPlaceholder.launchWindow == nil)
    }

    /// The launch window opens as the start screen alone, as a foreground
    /// launch leaves it: no agent palette (which, with nothing to take key
    /// status from it, stayed up over a background launch's window). The
    /// test host never hands it to the tracker.
    @Test func theLaunchWindowOpensWithoutThePaletteAndTheTestHostKeepsIt() async throws {
        guard let app = liveApp() else { return }

        let launch = withoutUndo(app) { app.leoOpenLaunchWindow() }
        defer { close(launch) }
        let session = try #require(launch.leoSession)

        #expect(!session.isPickerPresented)
        #expect(app.leoLaunchPlaceholder.launchWindow !== launch)
        await drainMainQueue()
        #expect(launch.window?.isVisible == true)
    }
}
