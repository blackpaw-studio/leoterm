import Testing

@testable import Ghostty

/// B-085: the empty window a launch opens on its own gives way to the first
/// window a script, App Intent, Service or opened file asks for -- as an
/// untouched untitled document does in a document app -- so a cold launch
/// those start ends with one window, however AppKit classified the launch.
/// It stays for good once the user touches Leo or it shows anything.
@MainActor
struct LeoLaunchPlaceholderTests {
    private final class FakeWindow: LeoLaunchPlaceholderWindow {
        var isPristineLeoPlaceholder = true
        private(set) var isClosed = false
        private(set) var spotsHeld = 0
        var onClose: () -> Void = {}

        func holdSpotForReplacement() { spotsHeld += 1 }

        func closeReplacedLeoPlaceholder() {
            isClosed = true
            onClose()
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
            openWindow: { tracker.adopt(open()) },
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
}
