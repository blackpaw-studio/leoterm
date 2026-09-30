import Testing

@testable import Ghostty

/// B-085: every launch opens Leo's first window, whether or not the app
/// ever becomes active (`open -g`, a login item, or the user clicking
/// another app while Leo launches -- macOS 14+ may then decline Leo's
/// activation). Exactly one launch event decides; later ones never add a
/// second window.
struct LeoInitialWindowGateTests {
    @Test func launchThatNeverActivatesStillOpensOneWindow() {
        var gate = LeoInitialWindowGate()

        let atLaunch = gate.shouldOpenInitialWindow(on: .didFinishLaunching, windowCount: 0, initialWindow: true)

        #expect(atLaunch)
        #expect(gate.isLaunchHandled)
    }

    @Test func activationAfterLaunchDoesNotOpenASecondWindow() {
        var gate = LeoInitialWindowGate()

        let atLaunch = gate.shouldOpenInitialWindow(on: .didFinishLaunching, windowCount: 0, initialWindow: true)
        // The window may still be setting up (count 0): the gate alone
        // must keep activation from opening another.
        let atActivation = gate.shouldOpenInitialWindow(on: .didBecomeActive, windowCount: 0, initialWindow: true)

        #expect(atLaunch)
        #expect(!atActivation)
        #expect(gate.handledBy == .didFinishLaunching)
    }

    /// Activation can land before the queued launch hop runs; then it opens
    /// the window and the hop does nothing.
    @Test func activationBeforeTheLaunchHopOpensTheOnlyWindow() {
        var gate = LeoInitialWindowGate()

        let atActivation = gate.shouldOpenInitialWindow(on: .didBecomeActive, windowCount: 0, initialWindow: true)
        let atLaunch = gate.shouldOpenInitialWindow(on: .didFinishLaunching, windowCount: 0, initialWindow: true)

        #expect(atActivation)
        #expect(!atLaunch)
        #expect(gate.handledBy == .didBecomeActive)
    }

    /// A window a launch document (`application(_:openFile:)`) already
    /// opened is the launch's window: no empty placeholder beside it.
    @Test func launchDocumentWindowSuppressesThePlaceholder() {
        var gate = LeoInitialWindowGate()

        let atLaunch = gate.shouldOpenInitialWindow(on: .didFinishLaunching, windowCount: 1, initialWindow: true)
        let atActivation = gate.shouldOpenInitialWindow(on: .didBecomeActive, windowCount: 0, initialWindow: true)

        #expect(!atLaunch)
        #expect(!atActivation)
        #expect(gate.isLaunchHandled)
    }

    @Test func initialWindowOffOpensNothingAtLaunch() {
        var gate = LeoInitialWindowGate()

        let atLaunch = gate.shouldOpenInitialWindow(on: .didFinishLaunching, windowCount: 0, initialWindow: false)
        let atActivation = gate.shouldOpenInitialWindow(on: .didBecomeActive, windowCount: 0, initialWindow: false)

        #expect(!atLaunch)
        #expect(!atActivation)
        #expect(gate.isLaunchHandled)
    }

    @Test func reopenBeforeLaunchIsHandledDoesNothing() {
        let gate = LeoInitialWindowGate()

        #expect(!gate.shouldOpenOnReopen(hasVisibleWindows: false, windowCount: 0))
    }

    /// A Dock click with no window left opens one -- including after a
    /// launch with `initial-window = false`.
    @Test func reopenWithNoWindowAfterLaunchOpensOne() {
        var gate = LeoInitialWindowGate()
        _ = gate.shouldOpenInitialWindow(on: .didFinishLaunching, windowCount: 0, initialWindow: false)

        #expect(gate.shouldOpenOnReopen(hasVisibleWindows: false, windowCount: 0))
    }

    /// A visible window is focused by AppKit; a window still setting up
    /// (not yet visible) must not get a twin.
    @Test func reopenWithAVisibleOrPendingWindowOpensNothing() {
        var gate = LeoInitialWindowGate()
        _ = gate.shouldOpenInitialWindow(on: .didFinishLaunching, windowCount: 0, initialWindow: true)

        #expect(!gate.shouldOpenOnReopen(hasVisibleWindows: true, windowCount: 1))
        #expect(!gate.shouldOpenOnReopen(hasVisibleWindows: false, windowCount: 1))
    }
}
