import AppKit
import Foundation
import Testing

@testable import Ghostty

/// B-050 against a real, shown start-screen `TerminalController`: what
/// `GhosttyAttachTabHost` reports as a lone untouched start tab, and when
/// it closes one. Needs the app's real `Ghostty.App`, so these bail out
/// (rather than fail) without it. Serialized: each test shows windows, and
/// windows shown side by side could land in one tab group.
///
/// No terminal surface is created here: other suites `setenv`/`unsetenv`
/// in the test host, which can leave Ghostty's environment snapshot
/// pointing at a shrunk `environ`, and a new surface then crashes the host.
/// The attach decisions themselves are covered against a fake host in
/// `LeoStartTabFillTests`.
@MainActor @Suite(.serialized) struct LeoStartTabFillIntegrationTests {
    private struct Fixture {
        let host: GhosttyAttachTabHost
        let controller: TerminalController
        let origin: LeoWindowID
    }

    /// A start-screen window as the user sees it: shown, with its split
    /// view (and so its editor and browser pane views) built. Registered
    /// with its own registry and host.
    private func makeFixture() async -> Fixture? {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return nil }
        let registry = LeoWindowSessionRegistry()
        let controller = makeStartWindow(ghostty)
        let session = registry.makeSession(window: controller.window, controller: controller, defaults: LeoInMemoryDefaults())
        let host = GhosttyAttachTabHost(registry: registry, requestConfigStore: LeoRequestConfigStore())
        await nextMainTurn()
        return Fixture(host: host, controller: controller, origin: session.id)
    }

    private func makeStartWindow(_ ghostty: Ghostty.App) -> TerminalController {
        let controller = TerminalController.leoNewPlaceholderWindow(ghostty)
        // Its own window, not a tab of whichever window is key: a new
        // terminal window prefers tabs until its first runloop turn.
        controller.window?.tabbingMode = .automatic
        return controller
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// Closes just the tabs the test made (never another window's).
    private func close(_ controllers: TerminalController...) {
        controllers.forEach { $0.closeTabImmediately(registerRedo: false) }
    }

    @Test func aShownStartWindowIsALoneStartTab() async throws {
        guard let fixture = await makeFixture() else { return }
        defer { close(fixture.controller) }

        #expect(fixture.controller.window?.isVisible == true)
        #expect(fixture.controller.leoSession?.editorPane != nil, "the pane views exist with nothing open in them")
        #expect(fixture.host.isLoneStartTab(origin: fixture.origin))
    }

    @Test func aStartTabBesideAnotherTabIsNotLone() async throws {
        guard let fixture = await makeFixture(), let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        let other = makeStartWindow(ghostty)
        defer { close(other, fixture.controller) }
        let window = try #require(fixture.controller.window)
        let otherWindow = try #require(other.window)

        window.addTabbedWindow(otherWindow, ordered: .above)
        await nextMainTurn()

        try #require(window.tabGroup?.windows.count == 2)
        #expect(!fixture.host.isLoneStartTab(origin: fixture.origin))
    }

    @Test func anUnknownWindowIsNotAStartTab() async {
        guard let fixture = await makeFixture() else { return }
        defer { close(fixture.controller) }

        #expect(!fixture.host.isLoneStartTab(origin: LeoWindowID()))
    }

    /// A sidebar click asks from inside the start window's own mouse
    /// event, so the window closes on the next turn, not under AppKit's
    /// feet.
    @Test func discardingTheStartTabWaitsForTheNextTurn() async throws {
        guard let fixture = await makeFixture() else { return }
        let window = try #require(fixture.controller.window)
        let flag = CloseFlag()
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in
            MainActor.assumeIsolated { flag.isClosed = true }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            if !flag.isClosed { close(fixture.controller) }
        }

        fixture.host.discardEmptyPlaceholder(origin: fixture.origin)
        #expect(!flag.isClosed, "not while the click is still being delivered")
        await nextMainTurn()

        #expect(flag.isClosed)
    }

    @MainActor private final class CloseFlag { var isClosed = false }
}
