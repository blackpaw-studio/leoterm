import AppKit
import GhosttyKit
import Testing

@testable import Ghostty

/// B-057 (D-111) against a real `TerminalController`: a plain shell shown
/// in a window's content area is a row in that window's Terminals section,
/// titled by its terminal. Switching away hides it -- the same surface,
/// never evicted, never counted against the pool -- and only closing it
/// ends it, showing its neighbour (or the start screen) in its place.
/// Needs the app's real `Ghostty.App`.
///
/// Windows are built but never shown or made key. An "agent" here runs
/// `/bin/cat`, never a real agent.
@MainActor @Suite(.serialized) struct LeoTerminalRowsIntegrationTests {
    private static let standIn = "/bin/cat"

    @MainActor private struct Fixture {
        let host: GhosttyAttachTabHost
        let configs: LeoRequestConfigStore
        let controller: TerminalController
        /// Where requests are routed from (the host's registry entry).
        let origin: LeoWindowID
        /// The window's own session -- its sidebar, and its handles' and
        /// hidden surfaces' window id.
        let session: LeoWindowSession
        let events: EventLog
        let closes: CloseLog

        var windowID: LeoWindowID { session.id }
        var terminals: LeoWindowTerminals { session.terminals }
        func shown() -> [Ghostty.SurfaceView] { Array(controller.surfaceTree) }
        func view(_ handle: AttachmentHandle) -> Ghostty.SurfaceView? { shown().first { $0.id == handle.surfaceID } }
    }

    @MainActor private final class EventLog {
        var events: [AttachLifecycleEvent] = []
        var task: Task<Void, Never>?
    }

    @MainActor private final class CloseLog {
        var windowClosed = false
        var observer: NSObjectProtocol?
    }

    private final class Weak {
        weak var view: Ghostty.SurfaceView?
        init(_ view: Ghostty.SurfaceView?) { self.view = view }
    }

    private static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    private func makeFixture() throws -> Fixture {
        let ghostty = try #require(Self.ghostty, "these tests need the app's Ghostty.App")
        let app = try #require(ghostty.app)
        let first = Ghostty.SurfaceView(app, baseConfig: nil)
        let controller = TerminalController(ghostty, withSurfaceTree: SplitTree(view: first))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let registry = LeoWindowSessionRegistry()
        let origin = registry.makeSession(window: controller.window, controller: controller, defaults: LeoInMemoryDefaults()).id
        let session = try #require(controller.leoSession)
        let configs = LeoRequestConfigStore()
        let host = GhosttyAttachTabHost(registry: registry, requestConfigStore: configs) { .init(isActive: false, keyWindow: nil) }
        // What `LeoRuntime` wires for the app's own sessions.
        let sessionID = session.id
        session.terminals.closeRequested = { [weak host] in host?.closeTerminal(AttachmentHandle(surfaceID: $0, windowID: sessionID)) }
        session.terminals.hasBusyHiddenShell = { [weak host] in host?.hiddenTerminalsNeedConfirmQuit(in: sessionID) ?? false }
        let log = EventLog()
        log.task = Task { [events = host.lifecycleEvents] in
            for await event in events { log.events.append(event) }
        }
        let closes = CloseLog()
        closes.observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [closes] _ in MainActor.assumeIsolated { closes.windowClosed = true } }
        return Fixture(host: host, configs: configs, controller: controller, origin: origin, session: session, events: log, closes: closes)
    }

    private func close(_ fixture: Fixture) {
        fixture.events.task?.cancel()
        fixture.closes.observer.map(NotificationCenter.default.removeObserver)
        fixture.controller.closeTabImmediately(registerRedo: false)
    }

    /// A new terminal row, as ⌘T makes one; `command` stands in for what
    /// its shell runs, and `input` is typed into it (via the request's
    /// inherited configuration).
    private func newShell(_ fixture: Fixture, running command: String? = nil, typing input: String? = nil) throws -> AttachmentHandle {
        let requestID = UUID()
        if command != nil || input != nil {
            var config = Ghostty.SurfaceConfiguration()
            config.command = command
            config.initialInput = input
            fixture.configs.set(config, for: requestID)
        }
        return try fixture.host.showInContent(command: "", workingDirectory: nil, origin: fixture.origin, requestID: requestID)
    }

    private func attachAgent(_ fixture: Fixture) throws -> AttachmentHandle {
        try fixture.host.showInContent(command: Self.standIn, workingDirectory: nil, origin: fixture.origin, requestID: UUID())
    }

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Rows

    @Test func aNewShellIsASelectedRowTitledByItsTerminal() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }

        let shell = try newShell(fixture)
        let view = try #require(fixture.view(shell))

        #expect(fixture.terminals.rows.map(\.id) == [shell.surfaceID])
        #expect(fixture.terminals.selection == shell.surfaceID, "⌘T selects it")
        view.setTitle("~/src/leo")
        #expect(await eventually { fixture.terminals.rows.first?.title == "~/src/leo" }, "live-updating")
    }

    @Test func aShellInASplitIsNotARow() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture)

        _ = try fixture.host.openSplit(
            command: "", workingDirectory: nil, origin: fixture.origin,
            sourceSurface: shell.surfaceID, direction: .right, requestID: UUID()
        )

        #expect(fixture.terminals.rows.map(\.id) == [shell.surfaceID], "B-058 decides what a split is")
    }

    @Test func eachWindowListsOnlyItsOwnShells() throws {
        let first = try makeFixture()
        let second = try makeFixture()
        defer { close(first); close(second) }

        let a = try newShell(first)
        let b = try newShell(second)

        #expect(first.terminals.rows.map(\.id) == [a.surfaceID])
        #expect(second.terminals.rows.map(\.id) == [b.surfaceID])
    }

    // MARK: Switching (D-111)

    @Test func switchingAwayHidesTheShellAndBackShowsTheSameInstance() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture)
        let original = try #require(fixture.view(shell))

        let agent = try attachAgent(fixture)

        #expect(fixture.host.isOpen(shell) && !fixture.host.isShown(shell), "hidden, not closed")
        #expect(fixture.terminals.rows.map(\.id) == [shell.surfaceID], "its row stays")
        #expect(fixture.terminals.selection == nil, "the agent is what the window shows")
        #expect(await eventually { original.window == nil }, "out of the view hierarchy")

        #expect(fixture.host.reveal(shell))

        #expect(fixture.shown().first === original, "the same surface: scrollback and process intact")
        #expect(fixture.terminals.selection == shell.surfaceID)
        #expect(fixture.host.isOpen(agent) && !fixture.host.isShown(agent), "the agent went to the pool")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!fixture.events.events.contains(.closed(shell)))
    }

    @Test func aHiddenShellIsNeverEvictedAndDoesNotCountTowardN() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture)
        let alive = Weak(fixture.view(shell))

        let agents = try (0...LeoLivePoolCapacity.perWindow).map { _ in try attachAgent(fixture) }

        #expect(fixture.host.isOpen(shell))
        #expect(alive.view != nil)
        #expect(await eventually { fixture.events.events.contains(.closed(agents[0])) }, "the least recent agent goes, as before")
        #expect(agents.dropFirst().allSatisfy(fixture.host.isOpen), "N bounds tmux clients: the shell isn't one")
    }

    /// Before D-111 this asked: an alert on a window that is never shown.
    /// One that did appear is dismissed (Cancel) so the suite never hangs.
    @Test(.timeLimit(.minutes(1)))
    func switchingAwayFromABusyShellNeverAsks() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        _ = try newShell(fixture, running: Self.standIn)
        let window = try #require(fixture.controller.window)

        let answer = Task { await fixture.host.confirmReplacingContent(origin: fixture.origin) }
        try? await Task.sleep(for: .milliseconds(200))
        let sheet = window.attachedSheet
        sheet.map { window.endSheet($0, returnCode: .alertSecondButtonReturn) }

        #expect(sheet == nil, "D-111: switching doesn't close it, so nothing to ask")
        #expect(await answer.value)
    }

    @Test func aBusyHiddenShellMakesClosingTheWindowAsk() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture, running: Self.standIn)
        let view = try #require(fixture.view(shell))
        #expect(!fixture.host.hiddenTerminalsNeedConfirmQuit(in: fixture.windowID), "shown, so the window's own check covers it")

        _ = try attachAgent(fixture)

        #expect(fixture.host.hiddenTerminalsNeedConfirmQuit(in: fixture.windowID) == view.needsConfirmQuit)
        #expect(fixture.terminals.hasBusyHiddenShell() == view.needsConfirmQuit, "what the window's close asks")
    }

    // MARK: Closing

    @Test func closingTheShownShellShowsItsNeighbour() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let first = try newShell(fixture)
        let neighbour = try #require(fixture.view(first))
        let closing = try newShell(fixture)
        let gone = Weak(fixture.view(closing))

        fixture.host.closeTerminal(closing)

        #expect(fixture.shown().first === neighbour, "the neighbour's own surface")
        #expect(fixture.terminals.rows.map(\.id) == [first.surfaceID])
        #expect(fixture.terminals.selection == first.surfaceID)
        #expect(await eventually { fixture.events.events.contains(.closed(closing)) })
        #expect(await eventually { gone.view == nil }, "its surface and pty are freed")
        #expect(!fixture.closes.windowClosed)
    }

    @Test func closingTheLastShellLeavesTheStartScreen() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture)

        fixture.host.closeTerminal(shell)

        #expect(fixture.controller.surfaceTree.isEmpty, "the start screen")
        #expect(fixture.terminals.rows.isEmpty, "the section hides")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!fixture.closes.windowClosed, "the window and its sidebar stay")
    }

    @Test func aShellShownAfterTheStartScreenKeepsTheWindowSize() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let window = try #require(fixture.controller.window)
        fixture.host.closeTerminal(try newShell(fixture))
        window.setContentSize(NSSize(width: 911, height: 533))
        let frame = window.frame

        _ = try newShell(fixture)

        #expect(window.frame == frame, "only a new window takes its initial size")
    }

    /// `exit` (and ⌘W once Ghostty's own confirm is answered) reaches the
    /// controller as a close of its root surface.
    @Test(arguments: [true, false])
    func exitingTheShownShellClosesTheRowNotTheWindow(_ hasNeighbour: Bool) async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let neighbour = hasNeighbour ? try newShell(fixture) : nil
        let closing = try newShell(fixture)
        let root = try #require(fixture.controller.surfaceTree.root)

        fixture.controller.closeSurface(root, withConfirmation: false)

        #expect(await eventually { !fixture.terminals.contains(closing.surfaceID) })
        #expect(fixture.shown().map(\.id) == [neighbour?.surfaceID].compactMap { $0 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!fixture.closes.windowClosed)
    }

    @Test func aHiddenShellWhoseProcessEndsLosesItsRow() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        // The user's own shell, told to `exit` (a command would wait for
        // a key) -- after a moment: Ghostty keeps a shell that ends at
        // once on screen as an abnormal exit.
        let shell = try newShell(fixture, typing: "sleep 1; exit\n")
        _ = try attachAgent(fixture)

        #expect(await eventually(.seconds(8)) { !fixture.terminals.contains(shell.surfaceID) })
        #expect(!fixture.host.isOpen(shell))
        #expect(fixture.shown().count == 1, "what the window shows is untouched")
    }

    @Test func closingTheWindowFreesItsHiddenShells() async throws {
        let fixture = try makeFixture()
        let shell = try newShell(fixture)
        let alive = Weak(fixture.view(shell))
        _ = try attachAgent(fixture)

        fixture.controller.window?.close()

        #expect(await eventually { alive.view == nil })
        #expect(await eventually { fixture.events.events.contains(.closed(shell)) })
        fixture.events.task?.cancel()
        fixture.closes.observer.map(NotificationCenter.default.removeObserver)
    }
}
