import AppKit
import Foundation
import Testing

@testable import Ghostty

/// B-050 against a real start-screen `TerminalController`: what
/// `GhosttyAttachTabHost` reports as a lone untouched start tab, and when
/// it closes one. Needs the app's real `Ghostty.App`, so these bail out
/// (rather than fail) without it.
///
/// The windows are built (content laid out, so the editor and browser pane
/// views exist as they do on screen) but never shown: suites run in
/// parallel in one app, and a shown window takes key status and the app's
/// activation from whichever suite is driving focus (B-050 fix round 1:
/// `GhosttyAttachTabHostFocusTests` lost its sidebar focus report). Every
/// test checks that its windows stayed hidden and never became key.
///
/// No terminal surface is created here; the attach decisions themselves are
/// covered against a fake host in `LeoStartTabFillTests`.
@MainActor @Suite(.serialized) struct LeoStartTabFillIntegrationTests {
    private struct Fixture {
        let host: GhosttyAttachTabHost
        let controller: TerminalController
        let origin: LeoWindowID
    }

    /// A start-screen window, laid out but not shown, registered with its
    /// own registry and host.
    private func makeFixture() -> Fixture? {
        guard let ghostty = Self.ghostty else { return nil }
        let registry = LeoWindowSessionRegistry()
        let controller = makeStartWindow(ghostty)
        let session = registry.makeSession(window: controller.window, controller: controller, defaults: LeoInMemoryDefaults())
        let host = GhosttyAttachTabHost(registry: registry, requestConfigStore: LeoRequestConfigStore())
        return Fixture(host: host, controller: controller, origin: session.id)
    }

    /// `leoNewPlaceholderWindow` without its presentation (show, cascade,
    /// activate the app).
    private func makeStartWindow(_ ghostty: Ghostty.App) -> TerminalController {
        let controller = TerminalController(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    private static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// Closes just the tabs the test made (never another window's).
    private func close(_ controllers: TerminalController...) {
        controllers.forEach { $0.closeTabImmediately(registerRedo: false) }
    }

    /// The test's windows stayed off screen and never took key status.
    private func expectLeftFocusAlone(_ windows: NSWindow?..., sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(windows.allSatisfy { $0?.isVisible != true }, "shown", sourceLocation: sourceLocation)
        #expect(windows.allSatisfy { $0?.isKeyWindow != true }, "took the key window", sourceLocation: sourceLocation)
    }

    @Test func aBuiltStartWindowIsALoneStartTab() async {
        guard let fixture = makeFixture() else { return }
        defer { close(fixture.controller) }
        await nextMainTurn()

        #expect(fixture.controller.leoSession?.editorPane != nil, "the pane views exist with nothing open in them")
        #expect(fixture.host.isLoneStartTab(origin: fixture.origin))
        expectLeftFocusAlone(fixture.controller.window)
    }

    @Test func aStartTabBesideAnotherTabIsNotLone() async throws {
        guard let fixture = makeFixture(), let ghostty = Self.ghostty else { return }
        let other = makeStartWindow(ghostty)
        defer { close(other, fixture.controller) }
        let window = try #require(fixture.controller.window)
        let otherWindow = try #require(other.window)

        window.addTabbedWindow(otherWindow, ordered: .above)
        await nextMainTurn()

        try #require(window.tabGroup?.windows.count == 2)
        #expect(!fixture.host.isLoneStartTab(origin: fixture.origin))
        expectLeftFocusAlone(window, otherWindow)
    }

    @Test func anUnknownWindowIsNotAStartTab() {
        guard let fixture = makeFixture() else { return }
        defer { close(fixture.controller) }

        #expect(!fixture.host.isLoneStartTab(origin: LeoWindowID()))
    }

    /// A sidebar click asks from inside the start window's own mouse
    /// event, so the window closes on the next turn, not under AppKit's
    /// feet.
    @Test func discardingTheStartTabWaitsForTheNextTurn() async throws {
        guard let fixture = makeFixture() else { return }
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
        expectLeftFocusAlone(window)
    }

    @MainActor private final class CloseFlag { var isClosed = false }
}
