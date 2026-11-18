import AppKit
import GhosttyKit
import LeoKit
import Testing

@testable import Ghostty

/// B-110 against real `TerminalController`s: a Leo surface dragged from one
/// Leo window into another -- dropped onto one of its panes, or onto no
/// window (a new one) -- belongs to the window it lands in, and the sidebar
/// there reaches it (P6). ⌘Z of the move puts it back only while neither
/// window changed since; otherwise it does nothing, so no undo frees a
/// shell without asking (P2). Needs the app's real `Ghostty.App`.
///
/// Two windows share one host and one registry, as the app's do. A and B
/// are built but never shown or made key; a window a drag opens is shown
/// (upstream shows it at once) and closed when the test ends. An "agent"
/// here runs `/bin/cat`, never a real agent.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), LeoCascadePointRestoringTrait()) struct LeoCrossWindowMoveTests {
    private static let standIn = "/bin/cat"

    @MainActor private struct Window {
        let controller: TerminalController
        /// The host's registry entry, which requests are routed from. Held
        /// here: the registry keeps its sessions weakly.
        let routing: LeoWindowSession
        /// The window's own session: its sidebar, and its handles' window id.
        let session: LeoWindowSession

        var origin: LeoWindowID { routing.id }
        var windowID: LeoWindowID { session.id }
        var terminals: LeoWindowTerminals { session.terminals }
        func shown() -> [Ghostty.SurfaceView] { Array(controller.surfaceTree) }
        func shows(_ view: Ghostty.SurfaceView?) -> Bool { shown().contains { $0 === view } }
        func view(_ handle: AttachmentHandle) -> Ghostty.SurfaceView? { shown().first { $0.id == handle.surfaceID } }
        func handle(_ id: UUID) -> AttachmentHandle { AttachmentHandle(surfaceID: id, windowID: windowID) }
    }

    @MainActor private struct Fixture {
        let host: GhosttyAttachContentHost
        let configs: LeoRequestConfigStore
        let registry: LeoWindowSessionRegistry
        let a: Window
        let b: Window
        let events: EventLog
    }

    @MainActor private final class EventLog {
        var events: [AttachLifecycleEvent] = []
        var task: Task<Void, Never>?
    }

    private final class Weak {
        weak var view: Ghostty.SurfaceView?
        init(_ view: Ghostty.SurfaceView?) { self.view = view }
    }

    private static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    /// `logsEvents`: the fixture reads the host's lifecycle events (one
    /// reader only); `false` leaves them to a coordinator a test makes.
    private func makeFixture(logsEvents: Bool = true) throws -> Fixture {
        let ghostty = try #require(Self.ghostty, "these tests need the app's Ghostty.App")
        let registry = LeoWindowSessionRegistry()
        let configs = LeoRequestConfigStore()
        let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: configs) { .init(isActive: false, keyWindow: nil) }
        let log = EventLog()
        if logsEvents {
            log.task = Task { [events = host.lifecycleEvents] in
                for await event in events { log.events.append(event) }
            }
        }
        return Fixture(
            host: host, configs: configs, registry: registry,
            a: try makeWindow(ghostty, registry: registry, host: host),
            b: try makeWindow(ghostty, registry: registry, host: host),
            events: log
        )
    }

    private func makeWindow(_ ghostty: Ghostty.App, registry: LeoWindowSessionRegistry, host: GhosttyAttachContentHost) throws -> Window {
        let app = try #require(ghostty.app)
        let first = Ghostty.SurfaceView(app, baseConfig: .leoStandIn(command: Self.standIn))
        let controller = TerminalController(ghostty, withSurfaceTree: SplitTree(view: first))
        let routing = registry.makeSession(window: controller.window, controller: controller, defaults: LeoInMemoryDefaults())
        let session = try #require(controller.leoSession)
        // What `LeoRuntime` wires for the app's own sessions.
        let id = session.id
        session.terminals.closeRequested = { [weak host] in host?.closeTerminal(AttachmentHandle(surfaceID: $0, windowID: id)) }
        session.terminals.hasBusyHiddenShell = { [weak host] in host?.hiddenTerminalsNeedConfirmQuit(in: id) ?? false }
        return Window(controller: controller, routing: routing, session: session)
    }

    /// Closes the fixture's windows (and `others`) without leaving a Close
    /// Window undo behind that could reopen them.
    private func close(_ fixture: Fixture, _ others: TerminalController?...) {
        fixture.events.task?.cancel()
        let controllers = [fixture.a.controller, fixture.b.controller] + others.compactMap { $0 }
        let undoManager = fixture.a.controller.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        for controller in controllers where !controller.leoWindowDidClose && controller.window != nil {
            controller.closeWindowImmediately()
        }
    }

    /// A new terminal row in `window`, as ⌘T makes one; `command` stands in
    /// for what its shell runs.
    private func newShell(_ fixture: Fixture, in window: Window, running command: String? = nil) throws -> AttachmentHandle {
        let requestID = UUID()
        // A plain row runs the stand-in, not the login shell: nothing here asserts what a shell does.
        fixture.configs.set(.leoStandIn(command: command ?? Self.standIn), for: requestID)
        return try fixture.host.showInContent(command: "", workingDirectory: nil, origin: window.origin, requestID: requestID)
    }

    /// ⌘D beside `pane` in `window`, as the coordinator routes it, kept out
    /// of undo (`LeoTerminalRowsIntegrationTests.openSplit` says why).
    /// `command`: an agent stand-in split, not a plain shell.
    private func openSplit(_ fixture: Fixture, in window: Window, beside pane: AttachmentHandle, command: String = "") throws -> AttachmentHandle {
        let undoManager = window.controller.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        return try fixture.host.openSplit(
            command: command, workingDirectory: nil, origin: window.origin,
            sourceSurface: pane.surfaceID, direction: .right, requestID: UUID()
        )
    }

    /// File ▸ Close or ⌘W on `pane`, one of a split's (its confirm already
    /// answered): the controller's own "Close Terminal".
    private func closePane(_ window: Window, _ pane: AttachmentHandle) throws {
        let view = try #require(window.view(pane))
        let node = try #require(window.controller.surfaceTree.root?.node(view: view))
        window.controller.closeSurface(node, withConfirmation: false)
    }

    /// `pane`, shown in another window, dropped onto `target` in `window`:
    /// upstream's drop, as its split view reports one.
    private func drop(_ pane: Ghostty.SurfaceView, onto target: Ghostty.SurfaceView, in window: Window) {
        window.controller.performSplitAction(.drop(.init(payload: pane, destination: target, zone: .right)))
    }

    /// A pane in `window` (`handle`'s) dropped onto `target`'s pane in
    /// `into`. Holds no strong reference past the call.
    private func drop(_ handle: AttachmentHandle, from window: Window, onto target: AttachmentHandle, in into: Window) throws {
        let pane = try #require(window.view(handle))
        let destination = try #require(into.view(target))
        drop(pane, onto: destination, in: into)
    }

    /// `handle`'s pane dragged out of `window` onto no window: upstream
    /// opens a new one for it. Returns that window's controller.
    private func dragToNewWindow(_ handle: AttachmentHandle, from window: Window) throws -> TerminalController? {
        let pane = try #require(window.view(handle))
        NotificationCenter.default.post(
            name: .ghosttySurfaceDragEndedNoTarget, object: pane,
            userInfo: [Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey: NSPoint(x: 240, y: 640)]
        )
        let owner = BaseTerminalController.controller(owning: pane) as? TerminalController
        return owner === window.controller ? nil : owner
    }

    /// The undo manager -- the app's one -- with nothing ⌘Z could replay
    /// from an earlier test, nor from these windows.
    private func freshUndo(_ fixture: Fixture) throws -> UndoManager {
        let undoManager = try #require(fixture.a.controller.undoManager)
        undoManager.removeAllActions(withTarget: fixture.a.controller)
        undoManager.removeAllActions(withTarget: fixture.b.controller)
        undoManager.leoRemoveActionsTestsCanReplay(ghostty: fixture.a.controller.ghostty)
        return undoManager
    }

    /// An undo group of its own below a move, for ⌘Z to reach once the
    /// move's own undo is gone: with nothing at all to undo in the event's
    /// open group, the app's undo manager raises (Edit ▸ Undo, which ⌘Z
    /// goes through, is disabled then).
    @MainActor private final class Mark {
        var isUndone = false
    }

    /// Registered as the app's own actions are, holding the mark weakly
    /// and expiring: one a failing test leaves behind does nothing when a
    /// later test's ⌘Z reaches it. (Plain `registerUndo(withTarget:)`
    /// doesn't retain its target, and replaying it once freed crashes the
    /// test host.)
    private func undoMark(_ undoManager: UndoManager) throws -> Mark {
        let expiring = try #require(undoManager as? ExpiringUndoManager)
        let mark = Mark()
        undoManager.leoInOwnUndoGroup {
            expiring.registerUndo(withTarget: mark, expiresAfter: .seconds(60)) { $0.isUndone = true }
        }
        return mark
    }

    /// Every undo and redo of `controllers` expiring, as `undo-timeout`
    /// would: theirs, and any move between them. The rest of the app's one
    /// undo manager -- other suites', which may run meanwhile -- is left be.
    private func expireUndo(_ undoManager: UndoManager, of controllers: TerminalController...) {
        controllers.forEach { controller in
            LeoCrossWindowMove.end(involving: controller)
            undoManager.removeAllActions(withTarget: controller)
        }
    }

    /// Lets the main run loop turn until `condition` holds, at most
    /// `limit` times: counts turns, not time (D-178).
    private func turns(limit: Int = 50, until condition: () -> Bool) async -> Bool {
        for _ in 0 ..< limit where !condition() { await nextTurn() }
        return condition()
    }

    /// Polls `condition` for up to `timeout` of wall time: for what waits on a timer.
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func settle(turns count: Int = 20) async {
        for _ in 0 ..< count { await nextTurn() }
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    // MARK: Ownership follows the surface

    /// A plain shell split beside A's row, dropped onto B's row: it is B's
    /// now -- a split beside B's row, with its handle there -- and B's
    /// sidebar reaches it: when B's row's pane closes, it carries the row
    /// on (P6, B-082).
    @Test func aShellDroppedIntoAnotherWindowBelongsToIt() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newShell(fixture, in: fixture.a)
        let split = try openSplit(fixture, in: fixture.a, beside: row)
        let q = try newShell(fixture, in: fixture.b)

        try drop(split, from: fixture.a, onto: q, in: fixture.b)

        try #require(fixture.b.view(split) != nil, "upstream's drop landed in B")
        let moved = fixture.b.handle(split.surfaceID)
        #expect(await turns { fixture.host.isOpen(moved) }, "its handle is B's")
        #expect(fixture.host.isShown(moved))
        #expect(!fixture.host.isOpen(split), "and no longer A's")
        #expect(fixture.a.terminals.rows.map(\.id) == [row.surfaceID])
        #expect(fixture.b.terminals.rows.map(\.id) == [q.surfaceID], "a split beside B's row, not a row")

        try closePane(fixture.b, q)

        #expect(await turns { fixture.b.terminals.rows.map(\.id) == [split.surfaceID] }, "it carries B's row on")
        #expect(fixture.b.terminals.selection == split.surfaceID)
    }

    /// A's row's own shell dropped into B: its row is handed on at home to
    /// the split left there (D-190); in B it is a split with its handle,
    /// and B's rows stay as they were (D-280).
    @Test func aRowsShellDroppedIntoAnotherWindowHandsItsRowOnAtHome() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newShell(fixture, in: fixture.a)
        let split = try openSplit(fixture, in: fixture.a, beside: row)
        let q = try newShell(fixture, in: fixture.b)

        try drop(row, from: fixture.a, onto: q, in: fixture.b)

        #expect(await turns { fixture.a.terminals.rows.map(\.id) == [split.surfaceID] }, "the split at home carries the row on")
        #expect(fixture.a.terminals.selection == split.surfaceID)
        let moved = fixture.b.handle(row.surfaceID)
        #expect(await turns { fixture.host.isOpen(moved) }, "its handle is B's")
        #expect(fixture.host.isShown(moved))
        #expect(fixture.b.terminals.rows.map(\.id) == [q.surfaceID], "a split in B, not a second row")
        #expect(fixture.b.terminals.selection == q.surfaceID)
    }

    /// A split dragged onto no window: the new window upstream opens for
    /// it shows only it, so it is that window's row, selected.
    @Test func aShellDraggedToANewWindowIsThatWindowsRow() async throws {
        let fixture = try makeFixture()
        var opened: TerminalController?
        defer { close(fixture, opened) }
        let row = try newShell(fixture, in: fixture.a)
        let split = try openSplit(fixture, in: fixture.a, beside: row)

        opened = try dragToNewWindow(split, from: fixture.a)

        let controller = try #require(opened, "upstream's drag opened a window for it")
        let session = try #require(controller.leoSession)
        let moved = AttachmentHandle(surfaceID: split.surfaceID, windowID: session.id)
        #expect(await turns { fixture.host.isOpen(moved) }, "its handle is the new window's")
        #expect(fixture.host.isShown(moved))
        #expect(session.terminals.rows.map(\.id) == [split.surfaceID], "its window's row")
        #expect(session.terminals.selection == split.surfaceID)
        #expect(fixture.a.terminals.rows.map(\.id) == [row.surfaceID])
    }

    /// An agent split dropped into B keeps its tracking: its handle moves
    /// (`.moved`), it never closes, so the coordinator still finds it there
    /// and attaches no second tmux client.
    @Test func anAgentDroppedIntoAnotherWindowStaysTracked() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newShell(fixture, in: fixture.a)
        let agent = try openSplit(fixture, in: fixture.a, beside: row, command: Self.standIn)
        let q = try newShell(fixture, in: fixture.b)

        try drop(agent, from: fixture.a, onto: q, in: fixture.b)

        let moved = fixture.b.handle(agent.surfaceID)
        #expect(await turns { fixture.events.events.contains(.moved(from: agent, to: moved)) })
        #expect(fixture.host.isOpen(moved))
        #expect(!fixture.events.events.contains(.closed(agent)), "nothing closed")
        #expect(fixture.b.terminals.rows.map(\.id) == [q.surfaceID], "an agent is never a terminal row")
    }

    /// The move sets both trees at once; the host moves the handle on the
    /// next turn. A Jump to the agent (or an attach) in between still finds
    /// it, in B -- not forgotten as closed, so its next attach would start a
    /// second tmux client. The real host: the fake has no turn in between.
    @Test func anAgentAskedForInTheTurnItMovesIsFoundInItsNewWindow() async throws {
        let fixture = try makeFixture(logsEvents: false)
        defer { close(fixture) }
        let coordinator = LeoAttachCoordinator(
            host: fixture.host, executable: { Self.standIn }, remoteCommandBuilder: { _, _ in Self.standIn }, report: { _ in }
        )
        let identity = LeoAgentIdentity(host: .remote("box"), name: "worker")
        let row = try newShell(fixture, in: fixture.a)
        let request = LeoSurfaceRequest(origin: fixture.a.origin, disposition: .split(.right), splitSourceSurface: row.surfaceID)
        let agent = try await coordinator.attach(identity: identity, request: request).get()
        let q = try newShell(fixture, in: fixture.b)

        try drop(agent, from: fixture.a, onto: q, in: fixture.b)
        let found = coordinator.focusExisting(identity)

        let moved = fixture.b.handle(agent.surfaceID)
        #expect(found, "brought forward in B, nothing attached anew")
        #expect(coordinator.identity(forSurface: agent.surfaceID) == identity, "still its agent")
        #expect(coordinator.linkState.attachCounts[LeoAgentRow.ID(host: identity.host, name: identity.name)] == 1, "shown once")
        #expect(await turns { fixture.host.isOpen(moved) })
        await settle()
        #expect(coordinator.identity(forSurface: agent.surfaceID) == identity, "still tracked once `.moved` arrives")
        #expect(coordinator.reusableHandleCount == 1)
    }

    /// An exited agent's pane shows its rebirth placeholder (Restart): it
    /// moves with the pane, so B shows it there and A keeps no stale one.
    @Test func anExitedAgentDroppedIntoAnotherWindowKeepsItsPlaceholder() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newShell(fixture, in: fixture.a)
        let agent = try openSplit(fixture, in: fixture.a, beside: row, command: Self.standIn)
        let q = try newShell(fixture, in: fixture.b)
        // What the coordinator asks for when the agent's process exits.
        fixture.host.rebirthPlaceholder(for: agent)
        try #require(fixture.a.session.placeholderSurfaceIDs == [agent.surfaceID])

        try drop(agent, from: fixture.a, onto: q, in: fixture.b)

        #expect(await turns { fixture.host.isOpen(fixture.b.handle(agent.surfaceID)) }, "its handle is B's")
        #expect(fixture.b.session.placeholderSurfaceIDs == [agent.surfaceID], "B shows its placeholder")
        #expect(fixture.a.session.placeholderSurfaceIDs.isEmpty, "A keeps no stale one")
    }

    /// An exited agent's pane dropped into B, and B closes in the same
    /// turn, before its handle can follow it there: the handle is let go,
    /// never moved into the closed window (where nothing would ever close
    /// it), and B shows no placeholder for it. A's own placeholder entry is
    /// left as any closed pane's is: ⌘Z on a pane's close relies on it.
    @Test func aPaneDroppedIntoAWindowClosingThatTurnIsNotMovedThere() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newShell(fixture, in: fixture.a)
        let agent = try openSplit(fixture, in: fixture.a, beside: row, command: Self.standIn)
        let q = try newShell(fixture, in: fixture.b)
        fixture.host.rebirthPlaceholder(for: agent)
        try #require(fixture.a.session.placeholderSurfaceIDs == [agent.surfaceID])

        try drop(agent, from: fixture.a, onto: q, in: fixture.b)
        let undoManager = fixture.b.controller.undoManager
        undoManager?.disableUndoRegistration()
        fixture.b.controller.closeWindowImmediately()
        undoManager?.enableUndoRegistration()

        #expect(await turns { fixture.events.events.contains(.closed(agent)) }, "its handle is let go")
        await settle()
        #expect(!fixture.events.events.contains { if case .moved = $0 { true } else { false } }, "never moved into B")
        #expect(!fixture.host.isOpen(fixture.b.handle(agent.surfaceID)))
        #expect(fixture.b.session.placeholderSurfaceIDs.isEmpty)
    }

    /// A's only pane dropped into B: A stays, showing its start screen, and
    /// nothing it keeps hidden dies (P2); upstream closed the emptied
    /// window, killing its hidden rows' shells without asking. ⌘Z refills
    /// A with it, its row again and focused; B goes back as it was.
    @Test func aWindowsOnlyPaneDroppedElsewhereLeavesItsStartScreen() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let undoManager = try freshUndo(fixture)
        let hidden = try newShell(fixture, in: fixture.a, running: Self.standIn)
        let row = try newShell(fixture, in: fixture.a)
        let q = try newShell(fixture, in: fixture.b)
        try #require(!fixture.host.isShown(hidden) && fixture.host.isOpen(hidden), "kept hidden for its row")
        let pane = Weak(fixture.a.view(row))
        let qPane = Weak(fixture.b.view(q))

        try undoManager.leoInOwnUndoGroup { try drop(row, from: fixture.a, onto: q, in: fixture.b) }

        #expect(!fixture.a.controller.leoWindowDidClose, "A stays")
        #expect(fixture.a.controller.surfaceTree.isEmpty, "showing its start screen")
        #expect(await turns { fixture.host.isOpen(fixture.b.handle(row.surfaceID)) }, "the pane is B's")
        #expect(fixture.host.isOpen(hidden), "the hidden row's shell lives")
        #expect(fixture.a.terminals.rows.map(\.id) == [hidden.surfaceID])
        await settle()

        undoManager.leoUndoLastGroup()

        #expect(fixture.a.shown().map(\.id) == [row.surfaceID], "back in A")
        #expect(!fixture.a.controller.leoIsUnfilledPlaceholder, "A is filled again")
        #expect(fixture.b.shown().map(\.id) == [q.surfaceID], "B as it was")
        #expect(await turns { fixture.host.isOpen(row) }, "its handle is A's again")
        #expect(fixture.a.terminals.rows.map(\.id) == [hidden.surfaceID, row.surfaceID], "a row in A again")
        #expect(fixture.a.terminals.selection == row.surfaceID)
        #expect(!fixture.events.events.contains(.closed(row)) && !fixture.events.events.contains(.closed(fixture.b.handle(row.surfaceID))))
        // Whether it reads focused can't be seen here: these windows are
        // never key, so each focus change marks their panes unfocused.
        // `Ghostty.moveFocus` retries on timers while a view isn't in its window yet, so this waits
        // on wall time, not turns: a run of main-queue hops can end before the first retry fires.
        let refocused = await eventually {
            fixture.a.controller.window?.firstResponder === pane.view && fixture.b.controller.window?.firstResponder === qPane.view
        }
        #expect(refocused, "focus back on it in A, and on Q in B")
    }

    // MARK: Undo after either window switched (P2)

    /// A, its row with a plain split beside it, and B, its row; that split
    /// dropped onto B's row, as one undo group. Returns A's row, B's row and
    /// the moved pane -- held weakly, so a test can see it free.
    private func splitDroppedIntoB(
        _ fixture: Fixture,
        _ undoManager: UndoManager
    ) throws -> (row: AttachmentHandle, q: AttachmentHandle, split: (handle: AttachmentHandle, view: Weak)) {
        let row = try newShell(fixture, in: fixture.a)
        let split = try openSplit(fixture, in: fixture.a, beside: row)
        let q = try newShell(fixture, in: fixture.b)
        let view = Weak(fixture.a.view(split))
        try undoManager.leoInOwnUndoGroup { try drop(split, from: fixture.a, onto: q, in: fixture.b) }
        try #require(fixture.b.shows(view.view), "upstream's drop landed in B")
        return (row, q, (split, view))
    }

    /// Drop S into B, switch A to another row, ⌘Z: S stays in B, shown and
    /// reachable there, and once nothing could redo the move it still runs
    /// -- before, B's half of the undo took S out of every tree, and S
    /// freed once that undo's redo expired.
    @Test func undoingAMoveAfterTheSourceSwitchesFreesNoShell() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let undoManager = try freshUndo(fixture)
        let mark = try undoMark(undoManager)
        let (_, _, split) = try splitDroppedIntoB(fixture, undoManager)
        await nextTurn()

        _ = try newShell(fixture, in: fixture.a)
        undoManager.leoUndoLastGroup()

        #expect(mark.isUndone, "the switch ended the move's undo: ⌘Z went past it")
        #expect(fixture.b.shows(split.view.view), "S stays in B")
        #expect(!fixture.a.shows(split.view.view))
        #expect(await turns { fixture.host.isShown(fixture.b.handle(split.handle.surfaceID)) }, "reachable from B")
        // Every undo and redo expiring: only what shows S holds it now.
        expireUndo(undoManager, of: fixture.a.controller, fixture.b.controller)
        await settle()
        #expect(split.view.view != nil, "S never freed")
        #expect(split.view.view?.processExited == false, "its shell still runs")
    }

    /// Drop S into B, switch B to another row, ⌘Z: A stays as the move left
    /// it -- before, A's half of the undo pulled S back in.
    @Test func undoingAMoveAfterTheDestinationSwitchesLeavesTheSourceAlone() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let undoManager = try freshUndo(fixture)
        let mark = try undoMark(undoManager)
        let (row, _, split) = try splitDroppedIntoB(fixture, undoManager)
        await nextTurn()

        let switched = try newShell(fixture, in: fixture.b)
        undoManager.leoUndoLastGroup()

        #expect(mark.isUndone, "the switch ended the move's undo: ⌘Z went past it")
        #expect(fixture.a.shown().map(\.id) == [row.surfaceID], "A as the move left it")
        #expect(!fixture.a.shows(split.view.view))
        #expect(fixture.b.shown().map(\.id) == [switched.surfaceID], "B as its switch left it")
        #expect(fixture.a.terminals.rows.map(\.id) == [row.surfaceID])
    }

    /// Drag S onto no window, switch A, ⌘Z: the new window stays, S shown
    /// in it, and S still runs once nothing could redo the move -- before,
    /// the undo closed the new window and S freed with its redo.
    @Test func undoingANewWindowMoveAfterTheSourceSwitchesKeepsTheNewWindow() async throws {
        let fixture = try makeFixture()
        var opened: TerminalController?
        defer { close(fixture, opened) }
        let undoManager = try freshUndo(fixture)
        let mark = try undoMark(undoManager)
        let row = try newShell(fixture, in: fixture.a)
        let split = try openSplit(fixture, in: fixture.a, beside: row)
        let view = Weak(fixture.a.view(split))
        opened = try undoManager.leoInOwnUndoGroup { try dragToNewWindow(split, from: fixture.a) }
        let controller = try #require(opened, "upstream's drag opened a window for it")
        let moved = AttachmentHandle(surfaceID: split.surfaceID, windowID: try #require(controller.leoSession).id)
        await nextTurn()

        _ = try newShell(fixture, in: fixture.a)
        undoManager.leoUndoLastGroup()

        #expect(mark.isUndone, "the switch ended the move's undo: ⌘Z went past it")
        #expect(!controller.leoWindowDidClose, "the new window stays")
        #expect(controller.surfaceTree.contains { $0 === view.view })
        #expect(await turns { fixture.host.isShown(moved) }, "reachable from its window")
        expireUndo(undoManager, of: fixture.a.controller, fixture.b.controller, controller)
        // Upstream's "New Window" redo, reopening the window with S, targets
        // the app's `Ghostty.App`, as `freshUndo` clears at every test's start.
        undoManager.removeAllActions(withTarget: controller.ghostty)
        await settle()
        #expect(view.view != nil, "S never freed")
        #expect(view.view?.processExited == false, "its shell still runs")
    }

    /// The move is an undo boundary for both windows, as a switch is
    /// (D-140): once the move's own undo is gone (B switched), ⌘Z never
    /// replays a tree A had before it -- which would bring S back into A,
    /// with no handle, while B had let it go.
    @Test func aMoveIsAnUndoBoundaryForBothWindows() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let undoManager = try freshUndo(fixture)
        let mark = try undoMark(undoManager)
        let row = try newShell(fixture, in: fixture.a)
        let split = try openSplit(fixture, in: fixture.a, beside: row)
        let other = try openSplit(fixture, in: fixture.a, beside: row)
        try undoManager.leoInOwnUndoGroup { try closePane(fixture.a, other) }
        let q = try newShell(fixture, in: fixture.b)
        try undoManager.leoInOwnUndoGroup { try drop(split, from: fixture.a, onto: q, in: fixture.b) }
        await nextTurn()
        _ = try newShell(fixture, in: fixture.b)

        undoManager.leoUndoLastGroup()

        #expect(fixture.a.shown().map(\.id) == [row.surfaceID], "A as the move left it")
        #expect(mark.isUndone, "nothing of A's from before the move was left to undo")
    }

    /// Closing either window ends the move, as a switch does: ⌘Z goes past
    /// it, and A stays as the move left it.
    @Test func closingAMovesWindowEndsIt() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let undoManager = try freshUndo(fixture)
        let mark = try undoMark(undoManager)
        let (row, _, _) = try splitDroppedIntoB(fixture, undoManager)
        await nextTurn()
        undoManager.disableUndoRegistration()
        fixture.b.controller.closeWindowImmediately()
        undoManager.enableUndoRegistration()

        undoManager.leoUndoLastGroup()

        #expect(mark.isUndone, "B's close ended the move's undo: ⌘Z went past it")
        #expect(fixture.a.shown().map(\.id) == [row.surfaceID], "A as the move left it")
    }

    /// Undoing a drop moves B's focus back, resigning what B focused --
    /// except the moved pane when the move emptied its source: undo
    /// focuses it there again, and resigning it after would leave it
    /// reading unfocused.
    @Test func undoingADropResignsWhatBFocusedUnlessItsEmptiedSourceRefocusesIt() {
        let pane = NSObject()
        let other = NSObject()
        let resigning = { (focused: NSObject?, emptied: Bool) in
            LeoCrossWindowMove.resigningOnUndo(focused: focused, moved: pane, sourceWasEmptied: emptied)
        }

        #expect(resigning(pane, true) == nil, "the emptied source focuses it again")
        #expect(resigning(pane, false) === pane)
        #expect(resigning(other, true) === other)
        #expect(resigning(other, false) === other)
        #expect(resigning(nil, true) == nil)
    }

    // MARK: Undo and redo of an intact move

    /// ⌘Z of a move neither window changed since puts S back in A -- its
    /// handle with it, a plain split again (D-280) -- closing the window a
    /// drag opened; redo moves it again, its handle along. Nothing else
    /// closes on the way.
    @Test(arguments: ["drop", "new window"])
    func undoingAndRedoingAnIntactMoveCarriesTheHandle(_ via: String) async throws {
        let fixture = try makeFixture()
        var opened: [TerminalController] = []
        defer { close(fixture, opened.first, opened.last) }
        let undoManager = try freshUndo(fixture)
        let row = try newShell(fixture, in: fixture.a)
        let split = try openSplit(fixture, in: fixture.a, beside: row)
        let q = try newShell(fixture, in: fixture.b)
        let view = Weak(fixture.a.view(split))
        let destination: () -> TerminalController? = {
            view.view.flatMap { BaseTerminalController.controller(owning: $0) as? TerminalController }
        }

        if via == "drop" {
            try undoManager.leoInOwnUndoGroup { try drop(split, from: fixture.a, onto: q, in: fixture.b) }
        } else {
            _ = try undoManager.leoInOwnUndoGroup { try dragToNewWindow(split, from: fixture.a) }
        }
        let moved = try #require(destination())
        opened += moved === fixture.b.controller ? [] : [moved]
        let movedHandle = AttachmentHandle(surfaceID: split.surfaceID, windowID: try #require(moved.leoSession).id)
        #expect(await turns { fixture.host.isOpen(movedHandle) })

        undoManager.leoUndoLastGroup()

        #expect(fixture.a.shows(view.view), "back in A")
        #expect(!moved.surfaceTree.contains { $0 === view.view } || moved.leoWindowDidClose)
        #expect(via == "drop" || moved.leoWindowDidClose, "the window the drag opened closes")
        #expect(await turns { fixture.host.isOpen(split) }, "its handle is A's again")
        #expect(fixture.a.terminals.rows.map(\.id) == [row.surfaceID], "a plain split, as it was")
        #expect(fixture.b.terminals.rows.map(\.id) == [q.surfaceID])

        undoManager.redo()

        let redone = try #require(destination())
        opened += redone === fixture.b.controller || redone === moved ? [] : [redone]
        #expect(redone !== fixture.a.controller, "moved again")
        let redoneHandle = AttachmentHandle(surfaceID: split.surfaceID, windowID: try #require(redone.leoSession).id)
        #expect(await turns { fixture.host.isOpen(redoneHandle) }, "its handle went along")
        #expect(fixture.a.terminals.rows.map(\.id) == [row.surfaceID])
        #expect(!fixture.events.events.contains(.closed(row)) && !fixture.events.events.contains(.closed(q)))
        #expect(!fixture.events.events.contains(.closed(split)) && !fixture.events.events.contains(.closed(movedHandle)))
    }

    /// The window a drag opened, tabbed since into A's (Merge All Windows,
    /// or Prefer Tabs): ⌘Z of the move closes only its own tab. A's tab
    /// stays, showing S back beside its row, and what A keeps hidden lives.
    @Test func undoingANewWindowMoveClosesOnlyItsTab() async throws {
        let fixture = try makeFixture()
        var opened: TerminalController?
        defer { close(fixture, opened) }
        let undoManager = try freshUndo(fixture)
        let hidden = try newShell(fixture, in: fixture.a, running: Self.standIn)
        let row = try newShell(fixture, in: fixture.a)
        let split = try openSplit(fixture, in: fixture.a, beside: row)
        let view = Weak(fixture.a.view(split))
        opened = try undoManager.leoInOwnUndoGroup { try dragToNewWindow(split, from: fixture.a) }
        let controller = try #require(opened, "upstream's drag opened a window for it")
        let tabs = try [fixture.a.controller, controller].map { try #require($0.window) }
        tabs.forEach { $0.tabbingMode = .automatic }
        tabs[0].addTabbedWindow(tabs[1], ordered: .above)
        try #require(tabs[0].tabGroup?.windows.count == 2, "AppKit grouped them")
        await nextTurn()

        undoManager.leoUndoLastGroup()

        #expect(controller.leoWindowDidClose, "its own tab closes")
        #expect(!fixture.a.controller.leoWindowDidClose, "A's stays")
        #expect(fixture.a.shows(view.view) && fixture.a.shown().count == 2, "S back beside its row")
        #expect(await turns { fixture.host.isOpen(split) }, "its handle is A's again")
        #expect(fixture.host.isOpen(row) && fixture.host.isOpen(hidden), "nothing of A's closed")
    }

    /// ⌘Z would close the window a drag opened: with unsaved editor edits
    /// there since, it does nothing -- the window stays, and S in it.
    @Test func undoingANewWindowMoveKeepsAWindowWithUnsavedEdits() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let fixture = try makeFixture()
            var opened: TerminalController?
            defer {
                // Its edits dropped, or its close would keep it.
                opened?.leoSession?.editor.tabs.forEach { $0.abandon() }
                close(fixture, opened)
            }
            let undoManager = try freshUndo(fixture)
            let row = try newShell(fixture, in: fixture.a)
            let split = try openSplit(fixture, in: fixture.a, beside: row)
            let view = Weak(fixture.a.view(split))
            opened = try undoManager.leoInOwnUndoGroup { try dragToNewWindow(split, from: fixture.a) }
            let controller = try #require(opened, "upstream's drag opened a window for it")
            let editor = try #require(controller.leoSession).editor
            try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("notes.txt", "notes")))
            let document = try #require(editor.document)
            document.edit(document.text + "!")
            try #require(controller.leoHasUnsavedEdits)

            undoManager.leoUndoLastGroup()

            #expect(!controller.leoWindowDidClose, "the window stays")
            #expect(controller.surfaceTree.contains { $0 === view.view }, "S stays in it")
            #expect(!fixture.a.shows(view.view))
        }
    }
}
