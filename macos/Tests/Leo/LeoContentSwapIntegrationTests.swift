import AppKit
import Testing

@testable import Ghostty

/// B-055 against a real `TerminalController`: showing a row replaces the
/// window's whole surface tree in place -- same window, same sidebar --
/// and lets the displaced surfaces go, so no attach (tmux client) is left
/// behind. Needs the app's real `Ghostty.App`, so these bail out (rather
/// than fail) without it.
///
/// The windows are built but never shown or made key (see
/// `LeoStartScreenIntegrationTests`: suites share one app), and the
/// surfaces run the default shell (`command: ""`), never an agent.
@MainActor @Suite(.serialized) struct LeoContentSwapIntegrationTests {
    private struct Fixture {
        let host: GhosttyAttachTabHost
        let controller: TerminalController
        let origin: LeoWindowID
        let events: EventLog

        func surface(_ handle: AttachmentHandle) -> Ghostty.SurfaceView? {
            controller.surfaceTree.first { $0.id == handle.surfaceID }
        }
    }

    @MainActor private final class EventLog {
        var events: [AttachLifecycleEvent] = []
        var task: Task<Void, Never>?
    }

    private static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    /// A hidden window already showing one plain surface (not a handle).
    private func makeFixture() -> Fixture? {
        guard let ghostty = Self.ghostty, let app = ghostty.app else { return nil }
        let first = Ghostty.SurfaceView(app, baseConfig: nil)
        let controller = TerminalController(ghostty, withSurfaceTree: SplitTree(view: first))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let registry = LeoWindowSessionRegistry()
        let session = registry.makeSession(window: controller.window, controller: controller, defaults: LeoInMemoryDefaults())
        let host = GhosttyAttachTabHost(registry: registry, requestConfigStore: LeoRequestConfigStore()) {
            .init(isActive: false, keyWindow: nil)
        }
        let log = EventLog()
        log.task = Task { [events = host.lifecycleEvents] in
            for await event in events { log.events.append(event) }
        }
        return Fixture(host: host, controller: controller, origin: session.id, events: log)
    }

    private func close(_ fixture: Fixture) {
        fixture.events.task?.cancel()
        fixture.controller.closeTabImmediately(registerRedo: false)
    }

    private func show(_ fixture: Fixture) throws -> AttachmentHandle {
        try fixture.host.showInContent(command: "", workingDirectory: nil, origin: fixture.origin, requestID: UUID())
    }

    /// Until `condition` holds, turning the main queue; gives up at a deadline.
    private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func showingARowReplacesTheWholeTreeInTheSameWindow() throws {
        guard let fixture = makeFixture() else { return }
        defer { close(fixture) }
        let window = fixture.controller.window
        let contentView = window?.contentView
        let session = fixture.controller.leoSession
        let before = Array(fixture.controller.surfaceTree)

        let handle = try show(fixture)

        let after = Array(fixture.controller.surfaceTree)
        #expect(after.map(\.id) == [handle.surfaceID], "one surface: the row now shown")
        #expect(before.allSatisfy { !fixture.controller.surfaceTree.contains($0) })
        #expect(fixture.controller.focusedSurface?.id == handle.surfaceID)
        #expect(fixture.controller.window === window, "the same window")
        #expect(window?.contentView === contentView, "the same content view: the sidebar isn't rebuilt")
        #expect(fixture.controller.leoSession === session, "the window's one sidebar session")
        #expect(handle.windowID == session?.id, "the window's own id")
    }

    @Test func aSplitLayoutIsReplacedWhole() throws {
        guard let fixture = makeFixture(), let app = Self.ghostty?.app else { return }
        defer { close(fixture) }
        let first = try #require(fixture.controller.surfaceTree.first)
        let second = Ghostty.SurfaceView(app, baseConfig: nil)
        fixture.controller.surfaceTree = try fixture.controller.surfaceTree.inserting(view: second, at: first, direction: .right)
        try #require(Array(fixture.controller.surfaceTree).count == 2)

        let handle = try show(fixture)

        #expect(Array(fixture.controller.surfaceTree).map(\.id) == [handle.surfaceID])
    }

    /// The leak guard: nothing keeps a displaced surface with no row to
    /// come back to alive, so its Ghostty surface and pty are freed. (A
    /// terminal row's shell is kept hidden instead, B-057; an agent is
    /// pooled, B-056.)
    @Test func aDisplacedSurfaceWithNoRowIsFreed() async throws {
        guard let fixture = makeFixture() else { return }
        defer { close(fixture) }
        weak var firstSurface = fixture.controller.surfaceTree.first
        try #require(firstSurface != nil)

        let second = try show(fixture)

        #expect(fixture.host.isOpen(second))
        #expect(await eventually { firstSurface == nil }, "the displaced surface (and its pty) is freed")
        #expect(!fixture.events.events.contains(.closed(second)))
    }

    @Test func switchingIsNotUndoable() throws {
        guard let fixture = makeFixture(), let undoManager = fixture.controller.undoManager else { return }
        defer { close(fixture) }
        undoManager.removeAllActions(withTarget: fixture.controller)
        undoManager.leoRemoveActionsTestsCanReplay(ghostty: fixture.controller.ghostty)
        let handle = try show(fixture)

        if undoManager.canUndo { undoManager.undo() }

        #expect(Array(fixture.controller.surfaceTree).map(\.id) == [handle.surfaceID], "undo never brings a let-go attach back")
    }

    @Test func theWindowTitleIsTheShownAgentsName() async throws {
        guard let fixture = makeFixture() else { return }
        defer { close(fixture) }
        let first = try show(fixture)
        fixture.host.setAgentName(first, name: "autopilot-scratch")
        #expect(await eventually { fixture.controller.window?.title == "autopilot-scratch" })

        let second = try show(fixture)
        fixture.host.setAgentName(second, name: "other-agent")

        #expect(await eventually { fixture.controller.window?.title == "other-agent" }, "D-095 carried over to the window")
    }

    @Test func anExitedPaneStopsCountingAsAPlaceholderOnceSwitchedAway() throws {
        guard let fixture = makeFixture(), let session = fixture.controller.leoSession else { return }
        defer { close(fixture) }
        let first = try show(fixture)
        session.rebirthPlaceholder(surfaceID: first.surfaceID)

        _ = try show(fixture)

        #expect(!session.placeholderSurfaceIDs.contains(first.surfaceID))
    }

    @Test func replacingAgentsOrAnIdleWindowNeverAsks() async throws {
        guard let fixture = makeFixture() else { return }
        defer { close(fixture) }
        let handle = try show(fixture)
        fixture.host.setAgentName(handle, name: "autopilot-scratch")

        #expect(await fixture.host.confirmReplacingContent(origin: fixture.origin), "an agent detaches losslessly")
        #expect(await fixture.host.confirmReplacingContent(origin: LeoWindowID()), "an unknown window has nothing to lose")
        #expect(fixture.controller.window?.attachedSheet == nil, "no alert was shown")
    }

    @Test func theWindowNeverTookFocus() throws {
        guard let fixture = makeFixture() else { return }
        defer { close(fixture) }

        _ = try show(fixture)

        #expect(fixture.controller.window?.isVisible != true)
        #expect(fixture.controller.window?.isKeyWindow != true)
    }
}
