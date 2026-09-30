import AppKit
import GhosttyKit
import Testing

@testable import Ghostty

/// B-056 against a real `TerminalController`: a row switched away from is
/// hidden with its very `Ghostty.SurfaceView` (so its tmux client, scrollback
/// and view state live on), shown again as the same instance, and freed
/// once evicted, released, or its window closes. Needs the app's real
/// `Ghostty.App`, so these bail out (rather than fail) without it.
///
/// Windows are built but never shown or made key (suites share one app).
/// An "attach" here runs `/bin/cat` -- a harmless long-lived process that
/// stands in for `leo agent attach`, never a real agent.
@MainActor @Suite(.serialized) struct LeoLivePoolIntegrationTests {
    private static let standIn = "/bin/cat"

    private struct Fixture {
        let host: GhosttyAttachContentHost
        let controller: TerminalController
        let origin: LeoWindowID
        let events: EventLog

        func shown() -> [Ghostty.SurfaceView] { Array(controller.surfaceTree) }
    }

    @MainActor private final class EventLog {
        var events: [AttachLifecycleEvent] = []
        var task: Task<Void, Never>?
    }

    /// Weak references to surfaces, so a test can tell which are still alive.
    @MainActor private final class Tracker {
        private var refs: [UUID: Weak] = [:]
        private final class Weak { weak var view: Ghostty.SurfaceView? }

        func track(_ view: Ghostty.SurfaceView?) {
            guard let view else { return }
            let ref = Weak()
            ref.view = view
            refs[view.id] = ref
        }

        func isAlive(_ handle: AttachmentHandle) -> Bool { refs[handle.surfaceID]?.view != nil }
        func view(_ handle: AttachmentHandle) -> Ghostty.SurfaceView? { refs[handle.surfaceID]?.view }
    }

    private static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    /// Fails (never passes vacuously) without the app's real Ghostty.App:
    /// `runtests.sh` runs the suite inside the Leo app, which has one.
    private func makeFixture() throws -> Fixture {
        let ghostty = try #require(Self.ghostty, "these tests need the app's Ghostty.App")
        let app = try #require(ghostty.app)
        let first = Ghostty.SurfaceView(app, baseConfig: nil)
        let controller = TerminalController(ghostty, withSurfaceTree: SplitTree(view: first))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let registry = LeoWindowSessionRegistry()
        let session = registry.makeSession(window: controller.window, controller: controller, defaults: LeoInMemoryDefaults())
        let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: LeoRequestConfigStore()) {
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

    private func attach(_ fixture: Fixture, _ tracker: Tracker, command: String = Self.standIn) throws -> AttachmentHandle {
        let handle = try fixture.host.showInContent(command: command, workingDirectory: nil, origin: fixture.origin, requestID: UUID())
        tracker.track(fixture.shown().first { $0.id == handle.surfaceID })
        return handle
    }

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func switchingBackShowsTheSameSurfaceInstance() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let tracker = Tracker()
        let first = try attach(fixture, tracker)
        let original = try #require(tracker.view(first))
        let second = try attach(fixture, tracker)

        #expect(fixture.host.isOpen(first), "hidden, still attached")
        #expect(!fixture.host.isShown(first))

        #expect(fixture.host.reveal(first))

        #expect(fixture.shown().count == 1)
        #expect(fixture.shown().first === original, "the same Ghostty.SurfaceView: scrollback and view state intact")
        #expect(fixture.controller.focusedSurface === original)
        #expect(fixture.host.isOpen(second) && !fixture.host.isShown(second), "what it replaced is hidden in turn")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!fixture.events.events.contains(.closed(first)))
        #expect(!fixture.events.events.contains(.closed(second)))
    }

    /// A surface still titled after an agent but with no attach handle --
    /// as upstream's Undo of Close Terminal puts it back after its handle
    /// closed -- is nothing the pool could reveal: switched away from, it
    /// is let go like a plain shell, never hidden as a tmux client that a
    /// new attach would then duplicate (B-056).
    @Test func aNamedSurfaceWithNoHandleIsLetGoNotPooled() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let tracker = Tracker()
        weak var orphan: Ghostty.SurfaceView?
        do {
            let view = try #require(fixture.shown().first)
            view.leoAgentName = "worker"
            orphan = view
        }

        let next = try attach(fixture, tracker)

        #expect(!fixture.host.hiddenSurfaces(in: next.windowID).contains { $0 === orphan }, "not pooled as an agent")
        #expect(fixture.host.hiddenSurfaces(in: next.windowID).isEmpty, "nothing hidden to count as a client")
        #expect(await eventually { orphan == nil }, "let go, so its surface is freed")
        #expect(fixture.host.isShown(next))
    }

    @Test func aHiddenSurfaceLeavesTheViewHierarchy() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let tracker = Tracker()
        let first = try attach(fixture, tracker)
        let view = try #require(tracker.view(first))
        #expect(await eventually { view.window != nil })

        _ = try attach(fixture, tracker)

        #expect(await eventually { view.window == nil }, "no layout, so no resize and no tmux reflow while hidden")
        #expect(!view.focused)
        #expect(!view.isWindowVisible, "occluded: the renderer stops drawing it")
    }

    @Test func aWindowResizeDoesNotResizeAHiddenSurface() async throws {
        let fixture = try makeFixture()
        let window = try #require(fixture.controller.window)
        defer { close(fixture) }
        let tracker = Tracker()
        let first = try attach(fixture, tracker)
        let view = try #require(tracker.view(first))
        #expect(await eventually { view.surfaceSize != nil })
        _ = try attach(fixture, tracker)
        #expect(await eventually { view.window == nil })
        let before = try #require(view.surfaceSize)

        window.setContentSize(NSSize(width: window.frame.width + 300, height: window.frame.height + 200))
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))

        let after = try #require(view.surfaceSize)
        #expect(after.columns == before.columns && after.rows == before.rows)
    }

    @Test func beyondFourTheLeastRecentlyViewedIsFreed() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let tracker = Tracker()
        let handles = try (0..<5).map { _ in try attach(fixture, tracker) }

        #expect(!fixture.host.isOpen(handles[0]))
        #expect(await eventually { fixture.events.events.contains(.closed(handles[0])) })
        #expect(await eventually { !tracker.isAlive(handles[0]) }, "its surface and pty are freed: the tmux client detaches")
        #expect(handles.dropFirst().allSatisfy(fixture.host.isOpen))
        #expect(handles.filter(tracker.isAlive).count == LeoLivePoolCapacity.perWindow)
    }

    /// D-111: a terminal row's shell is hidden for the row's life -- kept
    /// beside the pool, not in it (never evicted, never counted).
    @Test func aPlainShellRowIsKeptHiddenBesideThePool() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let tracker = Tracker()
        let shell = try attach(fixture, tracker, command: "")

        _ = try attach(fixture, tracker)

        #expect(fixture.host.isOpen(shell), "B-057: its row brings it back")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(tracker.isAlive(shell))
        #expect(fixture.host.hiddenSurfaces(in: shell.windowID).map(\.id) == [shell.surfaceID])
    }

    @Test func releasingLetsTheHiddenSurfaceGo() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let tracker = Tracker()
        let first = try attach(fixture, tracker)
        let second = try attach(fixture, tracker)

        fixture.host.release(first)
        fixture.host.release(second)

        #expect(!fixture.host.isOpen(first))
        #expect(fixture.host.isShown(second), "shown content is never released")
        #expect(await eventually { fixture.events.events.contains(.closed(first)) })
        #expect(await eventually { !tracker.isAlive(first) })
        #expect(!fixture.host.reveal(first))
    }

    @Test func closingTheWindowFreesItsHiddenSurfaces() async throws {
        let fixture = try makeFixture()
        let tracker = Tracker()
        let first = try attach(fixture, tracker)
        let second = try attach(fixture, tracker)
        _ = try attach(fixture, tracker)
        try #require(fixture.host.isOpen(first) && fixture.host.isOpen(second))

        fixture.controller.window?.close()

        #expect(await eventually { !tracker.isAlive(first) && !tracker.isAlive(second) }, "no tmux client outlives its window")
        #expect(!fixture.host.isOpen(first))
        #expect(await eventually { fixture.events.events.contains(.closed(first)) })
        fixture.events.task?.cancel()
    }

    /// Fix round 1: an agent split beside a plain shell is never pooled;
    /// displacing it (after D-106's ask) lets all of it go, so no hidden
    /// shell is ever in reach of a later eviction.
    @Test func aSplitHoldingAPlainShellIsNotPooled() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let tracker = Tracker()
        let agent = try attach(fixture, tracker)
        let app = try #require(Self.ghostty?.app)
        weak var shell: Ghostty.SurfaceView?
        do {
            let agentView = try #require(tracker.view(agent))
            let view = Ghostty.SurfaceView(app, baseConfig: nil)
            shell = view
            fixture.controller.surfaceTree = try fixture.controller.surfaceTree.inserting(view: view, at: agentView, direction: .right)
        }

        let next = try attach(fixture, tracker)

        #expect(next.windowID == agent.windowID)
        #expect(!fixture.host.isOpen(agent), "the agent went with the shell, at once")
        #expect(fixture.host.hiddenSurfaces(in: agent.windowID).isEmpty, "nothing with a shell in the pool for an eviction to kill")
        #expect(await eventually { !tracker.isAlive(agent) }, "the agent is freed, not kept hidden")
        #expect(await eventually { shell == nil }, "the shell is freed")
        #expect(fixture.host.isShown(next))
    }

    @Test func closingTheWindowClosesEachHandleOnce() async throws {
        let fixture = try makeFixture()
        let tracker = Tracker()
        let handles = try (0..<3).map { _ in try attach(fixture, tracker) }
        // Handles carry the controller's own session id; `fixture.origin` is
        // the test registry's, which the pool never keys by -- asserting on it
        // passed vacuously.
        let window = handles[0].windowID
        #expect(window != fixture.origin)
        #expect(fixture.host.hiddenSurfaces(in: window).count == 2, "the check below can fail")

        fixture.controller.window?.close()

        #expect(await eventually { handles.allSatisfy { fixture.events.events.contains(.closed($0)) } })
        try? await Task.sleep(for: .milliseconds(100))
        for handle in handles {
            #expect(fixture.events.events.filter { $0 == .closed(handle) }.count == 1)
        }
        #expect(fixture.host.hiddenSurfaces(in: window).isEmpty)
        fixture.events.task?.cancel()
    }

    /// B-057: a terminal row closing while its shell is hidden takes the
    /// shell's tree out of the keep and lets it go, once. `LeoLiveSurfaces`
    /// on its own, so what it lets go is counted directly.
    @Test func discardingAKeptTreeLetsItGo() throws {
        let keep = try KeptShell()
        try keep.hide()

        #expect(keep.live.discardKept(treeHolding: keep.shell, in: keep.window))

        #expect(keep.live.hiddenSurfaces(in: keep.window).isEmpty)
        #expect(!keep.live.contains(keep.shell, in: keep.window))
        #expect(keep.letGo.trees.map { $0.map(\.id) } == [[keep.shell.id]], "let go once")
        #expect(!keep.live.discardKept(treeHolding: keep.shell, in: keep.window), "nothing left to discard")
        #expect(keep.letGo.trees.count == 1)
    }

    /// B-057: a row's shell that has exited has nothing to show again, so
    /// nothing keeps it: switched away from once exited, taken to be shown,
    /// or dropped with the dead, it is let go -- once. (`hasExited` stands
    /// in for the shell's end.)
    @Test(arguments: ["hidden once exited", "taken", "dropped with the dead"])
    func aKeptShellThatExitedIsLetGo(_ path: String) throws {
        let keep = try KeptShell()
        if path != "hidden once exited" { try keep.hide() }
        keep.exit.hasExited = true

        switch path {
        case "hidden once exited": keep.live.hide(SplitTree(view: keep.shell), in: keep.window, showing: SplitTree())
        case "taken": #expect(keep.live.take(treeHolding: keep.shell, in: keep.window) == nil, "nothing to show")
        default: keep.live.dropDead()
        }

        #expect(keep.live.hiddenSurfaces(in: keep.window).isEmpty)
        #expect(keep.letGo.trees.map { $0.map(\.id) } == [[keep.shell.id]], "let go once")
    }

    /// B-057: Ghostty's close request for a kept shell is its row's to act
    /// on (the host closes the row, as ⌘W does), never the pool's: the
    /// pool's handling of it leaves the keep alone.
    @Test func aCloseRequestForAKeptShellIsNotThePools() throws {
        let keep = try KeptShell()
        try keep.hide()

        #expect(!keep.live.surfaceClosed(keep.shell), "not the pool's")

        #expect(keep.live.keptSurfaces(in: keep.window).map(\.id) == [keep.shell.id])
        #expect(keep.letGo.trees.isEmpty)
    }

    @MainActor private final class LetGoLog {
        var trees: [[Ghostty.SurfaceView]] = []
    }

    @MainActor private final class ExitFlag {
        var hasExited = false
    }

    /// `LeoLiveSurfaces` on its own with one terminal row's shell, so what
    /// it lets go is counted directly and the shell's exit is scripted.
    @MainActor private struct KeptShell {
        let window = LeoWindowID()
        let letGo: LetGoLog
        let exit: ExitFlag
        let shell: Ghostty.SurfaceView
        let live: LeoLiveSurfaces

        init() throws {
            let app = try #require(LeoLivePoolIntegrationTests.ghostty?.app, "these tests need the app's Ghostty.App")
            let shell = Ghostty.SurfaceView(app, baseConfig: nil)
            let letGo = LetGoLog()
            let exit = ExitFlag()
            self.shell = shell
            self.letGo = letGo
            self.exit = exit
            live = LeoLiveSurfaces(
                isAgent: { _ in false },
                isTerminalRow: { [weak shell] in $0 === shell },
                isClient: { _ in false },
                hasExited: { _ in exit.hasExited },
                letGo: { letGo.trees.append(Array($0)) }
            )
        }

        /// Switched away from: kept for its row.
        func hide() throws {
            live.hide(SplitTree(view: shell), in: window, showing: SplitTree())
            try #require(live.keptSurfaces(in: window).map(\.id) == [shell.id])
        }
    }

    @Test func aHiddenSurfaceWhoseProcessEndsIsLetGo() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let tracker = Tracker()
        let first = try attach(fixture, tracker, command: "/bin/sleep 1")
        _ = try attach(fixture, tracker)

        #expect(await eventually(.seconds(5)) { fixture.events.events.contains(.closed(first)) }, "as an agent restart ends a hidden attach")
        #expect(!fixture.host.isOpen(first))
        #expect(await eventually { !tracker.isAlive(first) })
    }
}
