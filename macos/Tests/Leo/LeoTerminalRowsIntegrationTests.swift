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
        guard !fixture.closes.windowClosed else { return }
        fixture.controller.closeTabImmediately(registerRedo: false)
    }

    /// A new terminal row, as ⌘T makes one; `command` stands in for what
    /// its shell runs, and `input` is typed into it (via the request's
    /// inherited configuration). `waiting`: once `command` ends, Ghostty
    /// waits for a key rather than asking to close (`wait-after-command`).
    private func newShell(
        _ fixture: Fixture,
        running command: String? = nil,
        typing input: String? = nil,
        waiting: Bool = false
    ) throws -> AttachmentHandle {
        let requestID = UUID()
        if command != nil || input != nil || waiting {
            var config = Ghostty.SurfaceConfiguration()
            config.command = command
            config.initialInput = input
            config.waitAfterCommand = waiting
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

        // A stand-in that never titles itself: a real shell's prompt can
        // retitle the row after `setTitle` (B-068).
        let shell = try newShell(fixture, running: Self.standIn)
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

    @Test func theStartScreenDropsTheClosedShellsWindowTitle() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        // A stand-in that never titles itself: a real shell's prompt can
        // retitle the window after `setTitle` (B-068).
        let shell = try newShell(fixture, running: Self.standIn)
        let view = try #require(fixture.view(shell))
        // What `TerminalView` reports once the shell has focus.
        fixture.controller.focusedSurfaceDidChange(to: view)
        view.setTitle("make test")
        #expect(await eventually { fixture.controller.window?.title == "make test" })

        fixture.host.closeTerminal(shell)

        #expect(fixture.controller.window?.title != "make test", "nothing on screen is titled that any more")
    }

    /// B-070: the start screen the last row leaves reads exactly as a new
    /// window's does ("👻 Ghostty", or the config's `title`), not a bare 👻.
    @Test func theStartScreenReadsANewWindowsTitle() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let fresh = TerminalController(fixture.controller.ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
        defer { fresh.window?.close() }
        let startTitle = try #require(fresh.window?.title)
        let shell = try newShell(fixture, running: Self.standIn)
        let view = try #require(fixture.view(shell))
        fixture.controller.focusedSurfaceDidChange(to: view)
        view.setTitle("make test")
        #expect(await eventually { fixture.controller.window?.title == "make test" })

        fixture.host.closeTerminal(shell)

        #expect(fixture.controller.window?.title == startTitle)
    }

    /// B-070: nor does its title bar keep the closed shell's directory as a
    /// proxy icon; a new window has none.
    @Test func theStartScreenDropsTheClosedShellsProxyIcon() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture, running: Self.standIn)
        let view = try #require(fixture.view(shell))
        fixture.controller.focusedSurfaceDidChange(to: view)
        // What `TerminalView` reports for the shell's working directory.
        fixture.controller.pwdDidChange(to: URL(fileURLWithPath: NSTemporaryDirectory()))
        try #require(fixture.controller.window?.representedURL != nil, "macos-titlebar-proxy-icon is visible by default")

        fixture.host.closeTerminal(shell)

        #expect(fixture.controller.window?.representedURL == nil)
    }

    /// B-070: a title chosen with Change Window Title… names the window, not
    /// the shell, so the start screen keeps it.
    @Test func aChosenWindowTitleOutlivesTheLastShell() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture, running: Self.standIn)
        let view = try #require(fixture.view(shell))
        fixture.controller.focusedSurfaceDidChange(to: view)
        fixture.controller.titleOverride = "Build box"

        fixture.host.closeTerminal(shell)

        #expect(fixture.controller.window?.title == "Build box")
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

    /// `exit` reaches the row a turn late (from inside libghostty's
    /// handling of that very surface), and ⌘W only once its confirm is
    /// answered: a reveal can hide the closing shell first. Its row still
    /// closes. (Driven without Ghostty's close notification, whose own
    /// observer would otherwise tidy up a hidden shell and mask this.)
    @Test func anExitRacingARevealStillClosesTheRow() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let neighbour = try newShell(fixture)
        let neighbourView = try #require(fixture.view(neighbour))
        let closing = try newShell(fixture)
        let gone = Weak(fixture.view(closing))

        fixture.controller.closeSurface(try #require(fixture.controller.surfaceTree.root), withConfirmation: false)
        #expect(fixture.host.reveal(neighbour), "in the same turn, before the close lands")

        #expect(await eventually { !fixture.terminals.contains(closing.surfaceID) }, "its row goes")
        #expect(!fixture.host.isOpen(closing), "nothing keeps it hidden for a row that's gone")
        #expect(await eventually { fixture.events.events.contains(.closed(closing)) })
        #expect(await eventually { gone.view == nil }, "its surface and pty are freed")
        #expect(fixture.shown().first === neighbourView, "what the reveal showed stays")
        #expect(fixture.terminals.selection == neighbour.surfaceID)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!fixture.closes.windowClosed)
    }

    /// Closing a row whose shell is hidden lets that shell go and leaves
    /// the content area -- and the sidebar's selection, even one arrowed
    /// onto another hidden row -- as they were.
    @Test func closingAHiddenShellsRowLetsItGo() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let selected = try newShell(fixture)
        let closing = try newShell(fixture)
        let gone = Weak(fixture.view(closing))
        let shown = try newShell(fixture)
        let shownView = try #require(fixture.view(shown))
        fixture.terminals.select(selected.surfaceID)

        fixture.host.closeTerminal(closing)

        #expect(fixture.terminals.rows.map(\.id) == [selected.surfaceID, shown.surfaceID])
        #expect(!fixture.host.isOpen(closing))
        #expect(fixture.shown().count == 1 && fixture.shown().first === shownView, "what the window shows is untouched")
        #expect(fixture.terminals.selection == selected.surfaceID, "the selection doesn't move")
        #expect(await eventually { fixture.events.events.contains(.closed(closing)) })
        #expect(await eventually { gone.view == nil }, "its surface and pty are freed")
    }

    /// Ghostty's close observer (`exit` on a hidden shell) and the row's
    /// deferred close can both run, in either order: whichever comes
    /// second finds nothing left to do.
    @Test(arguments: ["shown", "hidden", "hidden, after its exit"])
    func closingATerminalTwiceIsHarmless(_ state: String) async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let other = try newShell(fixture)
        let closing = try newShell(fixture)
        let closingView = try #require(fixture.view(closing))
        if state != "shown" { #expect(fixture.host.reveal(other)) }
        if state == "hidden, after its exit" {
            NotificationCenter.default.post(
                name: Ghostty.Notification.ghosttyCloseSurface, object: closingView, userInfo: ["process_alive": false]
            )
            #expect(await eventually { !fixture.terminals.contains(closing.surfaceID) })
        }

        fixture.host.closeTerminal(closing)
        fixture.host.closeTerminal(closing)

        #expect(fixture.terminals.rows.map(\.id) == [other.surfaceID])
        #expect(fixture.shown().map(\.id) == [other.surfaceID])
        #expect(fixture.terminals.selection == other.surfaceID)
        #expect(!fixture.host.isOpen(closing))
        #expect(await eventually { fixture.events.events.contains(.closed(closing)) })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.events.events.filter { $0 == .closed(closing) }.count == 1, "closed once")
        #expect(!fixture.closes.windowClosed)
    }

    // MARK: A hidden row's shell ending (fix round 2)

    /// Ghostty's close request for a hidden row's ended shell is the
    /// host's to act on (no controller shows that surface). A reveal
    /// landing before it is handled mustn't leave the row showing a shell
    /// that is gone. (The notification stands in for the shell's end.)
    @Test func aRevealRacingAHiddenShellsCloseRequestStillClosesTheRow() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let ending = try newShell(fixture)
        let endingView = try #require(fixture.view(ending))
        let neighbour = try newShell(fixture)
        let neighbourView = try #require(fixture.view(neighbour))

        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyCloseSurface, object: endingView, userInfo: ["process_alive": false]
        )
        #expect(fixture.host.reveal(ending), "in the same turn, before the close request is handled")

        #expect(await eventually { !fixture.terminals.contains(ending.surfaceID) }, "its row goes")
        #expect(!fixture.host.isOpen(ending))
        #expect(fixture.shown().count == 1 && fixture.shown().first === neighbourView, "its neighbour shows instead")
        #expect(fixture.terminals.selection == neighbour.surfaceID)
        #expect(await eventually { fixture.events.events.contains(.closed(ending)) })
        #expect(!fixture.closes.windowClosed)
    }

    /// Only a hidden shell's end closes its row from Ghostty's close
    /// request. One asking to close while its process lives (nothing
    /// reaches a hidden shell to ask that) is left be: a kept shell ends
    /// only by its row's close, or its exit (D-111).
    @Test func aHiddenShellsCloseRequestWhileItLivesLeavesItsRow() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let hidden = try newShell(fixture)
        let hiddenView = try #require(fixture.view(hidden))
        let shown = try newShell(fixture)

        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyCloseSurface, object: hiddenView, userInfo: ["process_alive": true]
        )
        try await Task.sleep(for: .milliseconds(200))

        #expect(fixture.terminals.contains(hidden.surfaceID), "its row stays")
        #expect(fixture.host.isOpen(hidden))
        #expect(fixture.host.isShown(shown))
        #expect(!fixture.events.events.contains(.closed(hidden)))
    }

    /// A row whose shell ended on screen (Ghostty waiting for a key) has
    /// nothing to come back to: switching away -- to an agent, or another
    /// row -- lets it go, and its row with it, rather than keeping it
    /// hidden.
    @Test(arguments: ["an agent", "another row"])
    func switchingAwayFromARowWhoseShellEndedLetsItGo(_ next: String) async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let other = try newShell(fixture)
        let ended = try newShell(fixture, running: "/bin/sleep 0.3", waiting: true)
        let endedView = try #require(fixture.view(ended))
        try #require(await eventually(.seconds(8)) { endedView.processExited })
        try #require(fixture.terminals.contains(ended.surfaceID))

        if next == "an agent" {
            _ = try attachAgent(fixture)
        } else {
            try #require(fixture.host.reveal(other))
        }

        #expect(!fixture.terminals.contains(ended.surfaceID), "its row goes")
        #expect(!fixture.host.isOpen(ended))
        #expect(!fixture.host.hiddenSurfaces(in: fixture.windowID).contains { $0 === endedView })
        #expect(await eventually { fixture.events.events.contains(.closed(ended)) })
    }

    /// Closing the shown row passes over a neighbour whose shell ended --
    /// that row went when it was switched away from -- to the next live
    /// one.
    @Test func closingTheShownShellSkipsANeighbourWhoseShellEnded() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let live = try newShell(fixture)
        let liveView = try #require(fixture.view(live))
        let ended = try newShell(fixture, running: "/bin/sleep 0.3", waiting: true)
        let endedView = try #require(fixture.view(ended))
        try #require(await eventually(.seconds(8)) { endedView.processExited })
        let closing = try newShell(fixture)

        fixture.host.closeTerminal(closing)

        #expect(fixture.shown().count == 1 && fixture.shown().first === liveView, "the next live row")
        #expect(fixture.terminals.rows.map(\.id) == [live.surfaceID])
        #expect(fixture.terminals.selection == live.surfaceID)
        #expect(!fixture.closes.windowClosed)
    }

    /// A hidden row's shell can end with no close request at all (Ghostty
    /// waits for a key, or the exit was abnormally quick): all that is
    /// heard is its windowless exit, and its row goes then.
    @Test func aHiddenShellThatEndsWithoutAskingToCloseLosesItsRow() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let ending = try newShell(fixture, running: "/bin/sleep 0.5", waiting: true)
        let agent = try attachAgent(fixture)

        #expect(await eventually(.seconds(8)) { !fixture.terminals.contains(ending.surfaceID) })
        #expect(!fixture.host.isOpen(ending))
        #expect(fixture.host.isShown(agent), "what the window shows stays")
    }

    /// A shell split beside a row has no row of its own to come back by,
    /// so switching away closes the whole content (the coordinator asks
    /// first when a shell in it is busy): nothing hidden holds a shell a
    /// later close could kill without asking.
    @Test func aRowWithAShellSplitBesideItIsNotKept() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newShell(fixture)
        let split = try fixture.host.openSplit(
            command: "", workingDirectory: nil, origin: fixture.origin,
            sourceSurface: row.surfaceID, direction: .right, requestID: UUID()
        )

        _ = try attachAgent(fixture)

        #expect(fixture.host.hiddenSurfaces(in: fixture.windowID).isEmpty)
        #expect(!fixture.host.isOpen(row) && !fixture.host.isOpen(split))
        #expect(!fixture.terminals.contains(row.surfaceID), "its row closes with it")
    }

    /// A row's shell closing while a shell is split beside it (⌘D) closes
    /// its own pane only, as a split's close does: the shell beside it --
    /// busy or not -- is never closed without asking.
    @Test func closingARowsShellLeavesTheShellSplitBesideIt() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newShell(fixture)
        let split = try fixture.host.openSplit(
            command: "", workingDirectory: nil, origin: fixture.origin,
            sourceSurface: row.surfaceID, direction: .right, requestID: UUID()
        )
        let splitView = try #require(fixture.view(split))

        fixture.host.closeTerminal(row)

        #expect(fixture.shown().count == 1 && fixture.shown().first === splitView, "the shell beside it stays")
        #expect(fixture.host.isOpen(split))
        #expect(!fixture.host.isOpen(row))
        #expect(!fixture.terminals.contains(row.surfaceID), "its row goes")
        #expect(fixture.terminals.selection == nil)
        #expect(await eventually { fixture.events.events.contains(.closed(row)) })
        #expect(!fixture.events.events.contains(.closed(split)))
        #expect(!fixture.closes.windowClosed)
    }

    // MARK: Undo across a content swap (B-071)

    /// This window's undo, emptied.
    private func freshUndo(_ fixture: Fixture) throws -> UndoManager {
        let undoManager = try #require(fixture.controller.undoManager)
        undoManager.removeAllActions(withTarget: fixture.controller)
        return undoManager
    }

    /// ⌘D beside `row`, as the coordinator routes it. `isUndoable: false`
    /// keeps its "New Split" out of undo: typed, ⌘D and a later ⌘W are
    /// two undo groups and ⌘Z undoes only ⌘W's, but the test host's busy
    /// run loop never ends an event's group (`groupsByEvent`), so both
    /// would share one and ⌘Z would undo the two at once.
    private func openSplit(
        _ fixture: Fixture,
        beside row: AttachmentHandle,
        isUndoable: Bool = true
    ) throws -> AttachmentHandle {
        let undoManager = isUndoable ? nil : fixture.controller.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        return try fixture.host.openSplit(
            command: "", workingDirectory: nil, origin: fixture.origin,
            sourceSurface: row.surfaceID, direction: .right, requestID: UUID()
        )
    }

    /// ⌘W on `split` (its confirm already answered): the controller's own
    /// undoable "Close Terminal".
    private func closeSplit(_ fixture: Fixture, _ split: AttachmentHandle) throws {
        let view = try #require(fixture.view(split))
        let node = try #require(fixture.controller.surfaceTree.root?.node(view: view))
        fixture.controller.closeSurface(node, withConfirmation: false)
    }

    /// `busy` was switched to after a split's undo was registered; ⌘Z
    /// came after. What the window shows stays, and the busy shell with
    /// it: no replayed tree drops it without asking.
    private func expectUndoLeftTheSwitchAlone(
        _ fixture: Fixture,
        busy: AttachmentHandle,
        busyView: Weak,
        rows: [UUID]
    ) async {
        #expect(fixture.shown().map(\.id) == [busy.surfaceID], "what the window shows stays")
        #expect(fixture.host.isShown(busy))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(busyView.view != nil, "its surface and pty live")
        #expect(!fixture.events.events.contains(.closed(busy)), "its row never closed")
        #expect(fixture.terminals.rows.map(\.id) == rows)
        #expect(fixture.terminals.selection == busy.surfaceID)
    }

    /// ⌘D, ⌘W the split, switch rows, ⌘Z: undo is a boundary a switch
    /// ends; the row left stays hidden, the busy one stays shown.
    @Test func undoingASplitCloseAfterASwitchLeavesTheShownRowAlone() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let undoManager = try freshUndo(fixture)
        let row = try newShell(fixture)
        let rowView = try #require(fixture.view(row))
        let split = try openSplit(fixture, beside: row, isUndoable: false)
        try closeSplit(fixture, split)
        let busy = try newShell(fixture, typing: "sleep 30\n")
        let busyView = Weak(fixture.view(busy))
        try #require(busyView.view != nil)

        undoManager.undo()

        await expectUndoLeftTheSwitchAlone(fixture, busy: busy, busyView: busyView, rows: [row.surfaceID, busy.surfaceID])
        #expect(fixture.host.hiddenSurfaces(in: fixture.windowID).contains { $0 === rowView }, "the row left is still kept")
        #expect(!fixture.host.isShown(row))
    }

    /// ⌘D, switch rows, ⌘Z (of "New Split"). Switching away from a row
    /// with a split beside it let both go (D-114), so only the busy row
    /// is left.
    @Test func undoingANewSplitAfterASwitchLeavesTheShownRowAlone() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let undoManager = try freshUndo(fixture)
        let row = try newShell(fixture)
        let rowView = Weak(fixture.view(row))
        _ = try openSplit(fixture, beside: row)
        let busy = try newShell(fixture, typing: "sleep 30\n")
        let busyView = Weak(fixture.view(busy))
        try #require(busyView.view != nil)

        undoManager.undo()

        await expectUndoLeftTheSwitchAlone(fixture, busy: busy, busyView: busyView, rows: [busy.surfaceID])
        #expect(!fixture.shown().contains { $0 === rowView.view }, "the let-go row isn't brought back")
    }

    /// The start screen the last row leaves is a boundary too: ⌘Z brings
    /// back neither the split closed before it nor the row.
    @Test func undoAfterTheLastShellLeavesTheStartScreenBringsNothingBack() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let undoManager = try freshUndo(fixture)
        let row = try newShell(fixture)
        let split = try openSplit(fixture, beside: row, isUndoable: false)
        try closeSplit(fixture, split)
        fixture.host.closeTerminal(row)
        try #require(fixture.controller.surfaceTree.isEmpty, "the start screen")

        undoManager.undo()

        #expect(fixture.controller.surfaceTree.isEmpty, "still the start screen")
        #expect(!fixture.terminals.contains(row.surfaceID))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!fixture.closes.windowClosed)
    }

    /// With no switch in between, ⌘Z of a split's close still brings the
    /// split back, as upstream's does.
    @Test func undoingASplitCloseWithoutASwitchStillRestoresIt() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let undoManager = try freshUndo(fixture)
        let row = try newShell(fixture)
        let split = try openSplit(fixture, beside: row, isUndoable: false)
        try closeSplit(fixture, split)
        try #require(fixture.shown().map(\.id) == [row.surfaceID])

        undoManager.undo()

        #expect(fixture.shown().map(\.id) == [row.surfaceID, split.surfaceID])
    }

    // MARK: Selection

    /// Showing a row it selected didn't happen (its confirm was cancelled,
    /// or its shell let go): the sidebar selects what the window does
    /// show -- its row, or none for an agent, so the agent's selection
    /// shows.
    @Test func theSelectionGoesBackToWhatTheWindowShows() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let hidden = try newShell(fixture)
        let shown = try newShell(fixture)
        fixture.terminals.select(hidden.surfaceID)

        fixture.host.selectShownTerminal(in: fixture.windowID)

        #expect(fixture.terminals.selection == shown.surfaceID)

        _ = try attachAgent(fixture)
        fixture.terminals.select(hidden.surfaceID)

        fixture.host.selectShownTerminal(in: fixture.windowID)

        #expect(fixture.terminals.selection == nil)
    }

    /// A hidden row the sidebar selected (arrowed onto, not shown) closing
    /// hands the selection to what the window shows: its row, or none, so
    /// the agent's selection shows (B-071, D-116).
    @Test(arguments: ["a row", "an agent"])
    func closingASelectedHiddenShellHandsTheSelectionToWhatIsShown(_ shown: String) throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let hidden = try newShell(fixture)
        let shownRow = shown == "a row" ? try newShell(fixture) : nil
        if shownRow == nil { _ = try attachAgent(fixture) }
        fixture.terminals.select(hidden.surfaceID)

        fixture.host.closeTerminal(hidden)

        #expect(!fixture.terminals.contains(hidden.surfaceID))
        #expect(fixture.terminals.selection == shownRow?.surfaceID)
    }

    /// Its shell exiting does the same.
    @Test func aSelectedHiddenShellThatExitsHandsTheSelectionToWhatIsShown() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        // As `aHiddenShellWhoseProcessEndsLosesItsRow`: the user's own
        // shell, told to `exit` after a moment.
        let exiting = try newShell(fixture, typing: "sleep 1; exit\n")
        let shown = try newShell(fixture)
        fixture.terminals.select(exiting.surfaceID)

        #expect(await eventually(.seconds(8)) { !fixture.terminals.contains(exiting.surfaceID) })
        #expect(fixture.terminals.selection == shown.surfaceID)
        #expect(fixture.host.isShown(shown))
    }

    // MARK: Tabs (unreachable while tabbing is disallowed, D-104 -- never silent)

    /// The start screen shows nothing to ask about, so only the hidden
    /// shell decides.
    @Test(arguments: [true, false])
    func aBusyHiddenShellCountsForClosingTabs(_ isBusy: Bool) throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        fixture.host.closeTerminal(try newShell(fixture))
        try #require(fixture.controller.surfaceTree.isEmpty)
        fixture.terminals.hasBusyHiddenShell = { isBusy }
        let window = try #require(fixture.controller.window)

        #expect(TerminalController.leoAnyNeedsConfirmClose([window]) == isBusy)
    }

    /// Quitting (⌘Q) asks each window whether it can close without
    /// confirmation; a busy shell it keeps hidden says no, as it does for
    /// Close Window.
    @Test(arguments: [true, false])
    func aBusyHiddenShellCountsForQuitting(_ isBusy: Bool) throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        fixture.host.closeTerminal(try newShell(fixture))
        try #require(fixture.controller.surfaceTree.isEmpty)
        fixture.terminals.hasBusyHiddenShell = { isBusy }

        #expect(fixture.controller.windowCanBeClosedWithoutConfirmation() == !isBusy)
    }

    /// Close Tab, Close Other Tabs and Close Tabs on the Right ask about a
    /// busy shell a closing window keeps hidden, as Close Window does. The
    /// app disallows tabbing, so the test groups two windows itself; each
    /// shows the start screen, so only the hidden shell asks. A sheet that
    /// appears is cancelled, so nothing closes and the suite never hangs.
    @Test(.timeLimit(.minutes(1)), arguments: ["Close Tab", "Close Other Tabs", "Close Tabs on the Right"])
    func closingTabsAsksForABusyHiddenShell(_ command: String) async throws {
        let left = try makeFixture()
        let right = try makeFixture()
        defer { close(left); close(right) }
        let windows = try [left, right].map { fixture in
            fixture.host.closeTerminal(try newShell(fixture))
            let window = try #require(fixture.controller.window)
            window.tabbingMode = .automatic
            return window
        }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        try #require(windows[0].tabGroup?.windows == windows, "AppKit grouped them, left to right")
        let (acting, closing) = switch command {
        case "Close Tab": (left, left)
        case "Close Other Tabs": (right, left)
        default: (left, right)
        }
        closing.terminals.hasBusyHiddenShell = { true }
        let asking = try #require(acting.controller.window)
        // A sheet reliably attaches only to a window on screen.
        asking.tabGroup?.selectedWindow = asking
        asking.orderFront(nil)

        switch command {
        case "Close Tab": acting.controller.closeTab(nil)
        case "Close Other Tabs": acting.controller.closeOtherTabs(nil)
        default: acting.controller.closeTabsOnTheRight(nil)
        }

        #expect(await eventually(.seconds(10)) { asking.attachedSheet != nil }, "it asks first")
        #expect(!closing.closes.windowClosed)
        asking.attachedSheet.map { asking.endSheet($0, returnCode: .alertSecondButtonReturn) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!closing.closes.windowClosed, "Cancel keeps it")
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
