import Testing

@testable import Ghostty

/// B-085: the launch hop, activation and reopen all go through one
/// `LeoInitialWindowOpener`, and so one gate: every launch opens exactly
/// one window from the hop, active or not. (A launch a script, App Intent
/// or Service started ends with only the window it asked for: see
/// `LeoLaunchPlaceholderTests`.)
@MainActor
struct LeoInitialWindowOpenerTests {
    /// Stands in for the app: the windows the opener opened (launch and
    /// reopen apart), and the launch hop queued but not yet run.
    private final class FakeApp {
        var opened = 0
        var reopened = 0
        var initialWindow = true
        var queued: [@MainActor () -> Void] = []

        var windowCount: Int { opened }

        @MainActor func runQueued() {
            let blocks = queued
            queued = []
            blocks.forEach { $0() }
        }
    }

    private func makeOpener(_ app: FakeApp) -> LeoInitialWindowOpener {
        LeoInitialWindowOpener(
            windowCount: { app.windowCount },
            initialWindow: { app.initialWindow },
            openWindow: { app.opened += 1 },
            openOnReopen: { app.reopened += 1 },
            schedule: { app.queued.append($0) }
        )
    }

    @Test func defaultLaunchOpensTheWindowFromTheHopWithoutActivation() {
        let app = FakeApp()
        let opener = makeOpener(app)

        opener.didFinishLaunching()
        let openedBeforeTheHop = app.opened
        app.runQueued()

        #expect(openedBeforeTheHop == 0)
        #expect(app.opened == 1)
    }

    @Test func activationAfterTheHopDoesNotOpenASecondWindow() {
        let app = FakeApp()
        let opener = makeOpener(app)

        opener.didFinishLaunching()
        app.runQueued()
        opener.didBecomeActive()
        opener.didBecomeActive()

        #expect(app.opened == 1)
    }

    @Test func activationBeforeTheHopOpensTheOnlyWindow() {
        let app = FakeApp()
        let opener = makeOpener(app)

        opener.didFinishLaunching()
        opener.didBecomeActive()
        app.runQueued()

        #expect(app.opened == 1)
    }

    @Test func reopenConsultsTheSameGate() {
        let app = FakeApp()
        let opener = makeOpener(app)

        opener.didFinishLaunching()
        let beforeTheHop = opener.shouldOpenOnReopen(hasVisibleWindows: false)
        app.runQueued()
        let withTheLaunchWindow = opener.shouldOpenOnReopen(hasVisibleWindows: true)
        app.opened = 0 // the user closed it
        let withNoWindowLeft = opener.shouldOpenOnReopen(hasVisibleWindows: false)

        #expect(!beforeTheHop)
        #expect(!withTheLaunchWindow)
        #expect(withNoWindowLeft)
    }

    /// B-095: a Dock click with no window left opens the start screen
    /// through the reopen opener (no palette, never adopted as a launch
    /// window) and tells AppKit it handled the reopen; otherwise it opens
    /// nothing and leaves AppKit its default.
    @Test func reopenOpensTheStartScreenOnlyWhenTheGateSays() {
        let app = FakeApp()
        let opener = makeOpener(app)

        opener.didFinishLaunching()
        let beforeTheHop = opener.reopen(hasVisibleWindows: false)
        app.runQueued()
        let withTheLaunchWindow = opener.reopen(hasVisibleWindows: true)
        let reopenedWithAWindow = app.reopened
        app.opened = 0 // the user closed it
        let withNoWindowLeft = opener.reopen(hasVisibleWindows: false)

        #expect(beforeTheHop)
        #expect(withTheLaunchWindow)
        #expect(reopenedWithAWindow == 0)
        #expect(!withNoWindowLeft)
        #expect(app.reopened == 1)
        #expect(app.opened == 0)
    }
}
