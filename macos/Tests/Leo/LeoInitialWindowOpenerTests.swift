import AppKit
import Testing

@testable import Ghostty

/// B-085: the launch hop, activation and reopen all go through one
/// `LeoInitialWindowOpener`, and so one gate. Every launch ends with
/// exactly one window: a default launch opens it from the hop, active or
/// not; a launch that came to run a script, an App Intent or a Service
/// ends with only the window that request opened.
@MainActor
struct LeoInitialWindowOpenerTests {
    /// Stands in for the app: windows the opener opened, windows a request
    /// opened, and the launch hop queued but not yet run.
    private final class FakeApp {
        var opened = 0
        var requested = 0
        var initialWindow = true
        var queued: [@MainActor () -> Void] = []

        var windowCount: Int { opened + requested }

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
            schedule: { app.queued.append($0) }
        )
    }

    @Test func defaultLaunchOpensTheWindowFromTheHopWithoutActivation() {
        let app = FakeApp()
        let opener = makeOpener(app)

        opener.didFinishLaunching(isDefaultLaunch: true)
        let openedBeforeTheHop = app.opened
        app.runQueued()

        #expect(openedBeforeTheHop == 0)
        #expect(app.opened == 1)
    }

    @Test func activationAfterTheHopDoesNotOpenASecondWindow() {
        let app = FakeApp()
        let opener = makeOpener(app)

        opener.didFinishLaunching(isDefaultLaunch: true)
        app.runQueued()
        opener.didBecomeActive()
        opener.didBecomeActive()

        #expect(app.opened == 1)
    }

    @Test func activationBeforeTheHopOpensTheOnlyWindow() {
        let app = FakeApp()
        let opener = makeOpener(app)

        opener.didFinishLaunching(isDefaultLaunch: true)
        opener.didBecomeActive()
        app.runQueued()

        #expect(app.opened == 1)
    }

    /// The review's blocking case: a cold `make new window` script, New
    /// Terminal intent or New Window Here service reaches the app after
    /// `applicationDidFinishLaunching` -- after the hop -- then activates it.
    /// The launch must end with only the requested window.
    @Test func requestLaunchEndsWithOnlyTheRequestedWindow() {
        let app = FakeApp()
        let opener = makeOpener(app)

        opener.didFinishLaunching(isDefaultLaunch: false)
        app.runQueued()
        app.requested += 1
        opener.didBecomeActive()

        #expect(app.opened == 0)
        #expect(app.windowCount == 1)
    }

    @Test func requestLaunchThatOpensNoWindowOpensOneOnActivation() {
        let app = FakeApp()
        let opener = makeOpener(app)

        opener.didFinishLaunching(isDefaultLaunch: false)
        app.runQueued()
        opener.didBecomeActive()

        #expect(app.opened == 1)
    }

    @Test func reopenConsultsTheSameGate() {
        let app = FakeApp()
        let opener = makeOpener(app)

        opener.didFinishLaunching(isDefaultLaunch: true)
        let beforeTheHop = opener.shouldOpenOnReopen(hasVisibleWindows: false)
        app.runQueued()
        let withTheLaunchWindow = opener.shouldOpenOnReopen(hasVisibleWindows: true)
        app.opened = 0 // the user closed it
        let withNoWindowLeft = opener.shouldOpenOnReopen(hasVisibleWindows: false)

        #expect(!beforeTheHop)
        #expect(!withTheLaunchWindow)
        #expect(withNoWindowLeft)
    }

    @Test func defaultLaunchReadsAppKitsKeyAndAssumesDefaultWithoutIt() {
        let key = NSApplication.launchIsDefaultUserInfoKey

        #expect(!LeoInitialWindowOpener.isDefaultLaunch(userInfo: [key: NSNumber(value: false)]))
        #expect(LeoInitialWindowOpener.isDefaultLaunch(userInfo: [key: NSNumber(value: true)]))
        #expect(LeoInitialWindowOpener.isDefaultLaunch(userInfo: nil))
        #expect(LeoInitialWindowOpener.isDefaultLaunch(userInfo: [:]))
    }
}
