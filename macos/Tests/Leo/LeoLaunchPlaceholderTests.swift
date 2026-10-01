import AppKit
import Testing

@testable import Ghostty

/// B-085: the empty window a launch opens on its own gives way to the first
/// window a script, App Intent, Service or opened file asks for -- as an
/// untouched untitled document does in a document app -- so a cold launch
/// those start ends with one window, however AppKit classified the launch.
/// It stays for good once the user touches Leo or it shows anything.
@MainActor
struct LeoLaunchPlaceholderTests {
    private final class FakeWindow: LeoLaunchPlaceholderWindow, LeoRequestedWindow {
        var isPristineLeoPlaceholder = true
        var isLeoWindowShown = true
        private(set) var isClosed = false
        private(set) var spotsHeld = 0
        /// Times the tracker closed it as replaced.
        private(set) var replacedCloses = 0
        private var closeObserver: (@MainActor () -> Void)?
        var onClose: () -> Void = {}

        var isObservingClose: Bool { closeObserver != nil }

        func holdSpotForReplacement() { spotsHeld += 1 }

        func closeReplacedLeoPlaceholder() {
            replacedCloses += 1
            isClosed = true
            isLeoWindowShown = false
            onClose()
        }

        func observeLeoWindowClose(_ onClose: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
            closeObserver = onClose
            return { [weak self] in self?.closeObserver = nil }
        }

        /// Closed by something other than the tracker: a script, the app.
        func closeOnItsOwn() {
            isClosed = true
            isLeoWindowShown = false
            closeObserver?()
        }
    }

    /// The input monitor and the main-queue hop, both under the test's control.
    private final class Harness {
        var queued: [@MainActor () -> Void] = []
        var onInput: (@MainActor () -> Void)?

        var isObservingInput: Bool { onInput != nil }

        @MainActor func runQueued() {
            while !queued.isEmpty {
                queued.removeFirst()()
            }
        }

        @MainActor func userTouchesLeo() { onInput?() }
    }

    private func makeTracker(_ harness: Harness) -> LeoLaunchPlaceholder {
        LeoLaunchPlaceholder(
            observeUserInput: { callback in
                harness.onInput = callback
                return { harness.onInput = nil }
            },
            schedule: { harness.queued.append($0) }
        )
    }

    @Test func requestedWindowReplacesTheUntouchedLaunchWindow() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()
        let requested = FakeWindow()

        tracker.adopt(launch)
        tracker.windowDidOpen(requested)
        let closedBeforeTheRequestedWindowShows = launch.isClosed
        harness.runQueued()

        #expect(!closedBeforeTheRequestedWindowShows)
        #expect(launch.isClosed)
        #expect(!requested.isClosed)
    }

    /// The requested window cascades onto the launch window's spot rather
    /// than one step off it: held before the requested window shows (a
    /// new-tab window cascades as it shows) and again as the launch window
    /// closes (a new window cascades a turn later).
    @Test func requestedWindowTakesTheLaunchWindowsSpot() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()

        tracker.adopt(launch)
        tracker.windowDidOpen(FakeWindow())
        let heldBeforeTheRequestedWindowShows = launch.spotsHeld

        #expect(heldBeforeTheRequestedWindowShows == 1)
    }

    @Test func launchWindowTheUserTouchedStays() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()

        tracker.adopt(launch)
        harness.userTouchesLeo()
        tracker.windowDidOpen(FakeWindow())
        harness.runQueued()

        #expect(!launch.isClosed)
        #expect(!harness.isObservingInput)
    }

    @Test func launchWindowShowingAnAgentOrTerminalStays() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()

        tracker.adopt(launch)
        launch.isPristineLeoPlaceholder = false
        tracker.windowDidOpen(FakeWindow())
        harness.runQueued()

        #expect(!launch.isClosed)
    }

    @Test func launchWindowFilledBeforeItsTurnToCloseStays() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()

        tracker.adopt(launch)
        tracker.windowDidOpen(FakeWindow())
        launch.isPristineLeoPlaceholder = false
        harness.runQueued()

        #expect(!launch.isClosed)
    }

    @Test func onlyTheFirstRequestedWindowReplacesIt() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()
        let first = FakeWindow()
        let second = FakeWindow()

        tracker.adopt(launch)
        tracker.windowDidOpen(first)
        harness.runQueued()
        tracker.windowDidOpen(second)
        harness.runQueued()

        #expect(launch.isClosed)
        #expect(!first.isClosed)
        #expect(!second.isClosed)
        #expect(!harness.isObservingInput)
    }

    /// The review's P1 case: a requested window whose presentation failed
    /// or was cancelled must not take the launch window with it.
    @Test func requestedWindowThatNeverShowsLeavesTheLaunchWindow() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()
        let requested = FakeWindow()
        requested.isLeoWindowShown = false

        tracker.adopt(launch)
        tracker.windowDidOpen(requested)
        harness.runQueued()

        #expect(!launch.isClosed)
    }

    @Test func requestedWindowGoneBeforeItsTurnLeavesTheLaunchWindow() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()

        tracker.adopt(launch)
        do {
            let requested = FakeWindow()
            tracker.windowDidOpen(requested)
        }
        harness.runQueued()

        #expect(!launch.isClosed)
    }

    /// Something closed the launch window without a key or mouse press (a
    /// script's `close window 1`): the tracker lets it go, so a later
    /// request neither takes its old spot nor closes it again.
    @Test func launchWindowClosedOnItsOwnIsForgotten() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()

        tracker.adopt(launch)
        launch.closeOnItsOwn()
        let isForgotten = tracker.launchWindow == nil
        let stoppedObserving = !harness.isObservingInput && !launch.isObservingClose
        tracker.windowDidOpen(FakeWindow())
        harness.runQueued()

        #expect(isForgotten)
        #expect(stoppedObserving)
        #expect(launch.spotsHeld == 0)
    }

    /// A window the launch window's own start screen opened (Start daemon,
    /// ssh) -- by an accessibility press, say, which is no key or mouse
    /// event -- leaves it where it is.
    @Test func windowTheLaunchWindowAskedForLeavesIt() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()

        tracker.adopt(launch)
        tracker.windowDidOpen(FakeWindow(), parent: launch)
        harness.runQueued()

        #expect(!launch.isClosed)
        #expect(launch.spotsHeld == 0)
        #expect(tracker.launchWindow == nil)
    }

    @Test func pressingOrScrollingAnywhereInLeoCountsAsTouchingIt() {
        let touches: [NSEvent.EventTypeMask] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]

        #expect(touches.allSatisfy { LeoLaunchPlaceholder.touchEvents.contains($0) })
        #expect(!LeoLaunchPlaceholder.touchEvents.contains(.mouseMoved), "passing the pointer over it is not a touch")
    }

    /// In an XCTest host the launch window is never handed over: tests
    /// open real windows, and must not close the host's.
    @Test func trackerThatSkipsLaunchWindowsLeavesThemAlone() {
        let harness = Harness()
        let tracker = LeoLaunchPlaceholder(
            adoptsLaunchWindows: false,
            observeUserInput: { callback in
                harness.onInput = callback
                return { harness.onInput = nil }
            },
            schedule: { harness.queued.append($0) }
        )
        let launch = FakeWindow()

        tracker.launchDidOpen(launch)
        tracker.windowDidOpen(FakeWindow())
        harness.runQueued()

        #expect(!launch.isClosed)
        #expect(tracker.launchWindow == nil)
        #expect(!harness.isObservingInput)
    }

    @Test func theLaunchWindowItselfIsNotARequest() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()

        tracker.adopt(launch)
        tracker.windowDidOpen(launch)
        harness.runQueued()

        #expect(!launch.isClosed)
        #expect(harness.isObservingInput)
    }

    /// The review's blocking case: the hop opens the launch window, then a
    /// cold `make new window` script, New Terminal intent or New Window
    /// Here service opens its window and activates the app. One is left.
    @Test func requestLaunchEndsWithOnlyTheRequestedWindow() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        var windows: [FakeWindow] = []
        func open() -> FakeWindow {
            let window = FakeWindow()
            window.onClose = { windows.removeAll { $0 === window } }
            windows.append(window)
            return window
        }
        let opener = LeoInitialWindowOpener(
            windowCount: { windows.count },
            initialWindow: { true },
            openWindow: { tracker.launchDidOpen(open()) },
            schedule: { harness.queued.append($0) }
        )

        opener.didFinishLaunching()
        harness.runQueued()
        let requested = open()
        tracker.windowDidOpen(requested)
        opener.didBecomeActive()
        harness.runQueued()

        #expect(windows.count == 1)
        #expect(windows.first === requested)
    }

    /// The review's narrow double close: something else closed the launch
    /// window between the request and the queued close (a script's `close
    /// window 1` on the same turn). The tracker had already let go of it,
    /// so the queued close must check it is still open.
    @Test func launchWindowClosedBeforeItsTurnIsNotClosedAgain() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()

        tracker.adopt(launch)
        tracker.windowDidOpen(FakeWindow())
        launch.closeOnItsOwn()
        harness.runQueued()

        #expect(launch.replacedCloses == 0)
    }

    /// A hidden launch (`open -j`, a login item set to hide): every window
    /// of a hidden app reads `isVisible == false`, so on-screen alone would
    /// leave both windows. Presented and still open counts as shown then.
    @Test func hiddenLaunchStillEndsWithOnlyTheRequestedWindow() {
        let harness = Harness()
        let tracker = makeTracker(harness)
        let launch = FakeWindow()
        let requested = FakeWindow()
        let shownWhileHidden = LeoWindowPresence.isShown(presented: true, closed: false, isVisible: false, appIsHidden: true)
        launch.isLeoWindowShown = shownWhileHidden
        requested.isLeoWindowShown = shownWhileHidden

        tracker.adopt(launch)
        tracker.windowDidOpen(requested)
        harness.runQueued()

        #expect(launch.replacedCloses == 1)
        #expect(!requested.isClosed)
    }

    @Test func presentedWindowOfAHiddenAppCountsAsShown() {
        #expect(LeoWindowPresence.isShown(presented: true, closed: false, isVisible: false, appIsHidden: true))
    }

    @Test func windowOfAHiddenAppThatNeverPresentedIsNotShown() {
        #expect(!LeoWindowPresence.isShown(presented: false, closed: false, isVisible: false, appIsHidden: true))
    }

    @Test func closedWindowOfAHiddenAppIsNotShown() {
        #expect(!LeoWindowPresence.isShown(presented: true, closed: true, isVisible: false, appIsHidden: true))
    }

    /// Not hidden, the window must really be on screen: a presentation that
    /// failed leaves the launch window, never no window (B-085).
    @Test func windowOfAVisibleAppMustBeOnScreen() {
        #expect(!LeoWindowPresence.isShown(presented: true, closed: false, isVisible: false, appIsHidden: false))
        #expect(LeoWindowPresence.isShown(presented: true, closed: false, isVisible: true, appIsHidden: false))
    }
}
