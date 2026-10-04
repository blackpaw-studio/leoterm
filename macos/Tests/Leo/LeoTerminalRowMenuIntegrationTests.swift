import AppKit
import GhosttyKit
import Testing

@testable import Ghostty

/// B-177 against a real `TerminalController`: a terminal row's context
/// menu renames its shell (the one title the row, the window and a close
/// confirm read, sticking over the terminal's own until cleared, and
/// surviving the surface's restorable encoding) and closes it, asking
/// first as ⌘W does when a process is running. Needs the app's real
/// `Ghostty.App`; windows are built but never made key, and a busy shell
/// runs `/bin/cat`, never a real agent.
@MainActor @Suite(.serialized) struct LeoTerminalRowMenuIntegrationTests {
    private static let standIn = "/bin/cat"

    @MainActor private struct Fixture {
        let host: GhosttyAttachContentHost
        let configs: LeoRequestConfigStore
        let controller: TerminalController
        let origin: LeoWindowID
        let session: LeoWindowSession

        var windowID: LeoWindowID { session.id }
        var terminals: LeoWindowTerminals { session.terminals }
        func shown() -> [Ghostty.SurfaceView] { Array(controller.surfaceTree) }
        func view(_ handle: AttachmentHandle) -> Ghostty.SurfaceView? { shown().first { $0.id == handle.surfaceID } }
        func label(_ handle: AttachmentHandle) -> String? { terminals.list.labels.first { $0.id == handle.surfaceID }?.text }
    }

    /// Cancels the first alert sheet that appears on a window, noting what
    /// it said.
    @MainActor private final class SheetWatch {
        private(set) var sawSheet = false
        private(set) var texts: [String] = []

        func cancelAny(on window: NSWindow) async {
            while !Task.isCancelled {
                if let sheet = window.attachedSheet {
                    sawSheet = true
                    texts = Self.texts(in: sheet.contentView)
                    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        private static func texts(in view: NSView?) -> [String] {
            guard let view else { return [] }
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
            return own + view.subviews.flatMap { texts(in: $0) }
        }
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
        let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: configs) { .init(isActive: false, keyWindow: nil) }
        // What `LeoRuntime` wires for the app's own sessions.
        let window = session.id
        session.terminals.closeRequested = { [weak host] in host?.closeTerminal(AttachmentHandle(surfaceID: $0, windowID: window)) }
        session.terminals.renameRequested = { [weak host] in host?.renameTerminal(AttachmentHandle(surfaceID: $0, windowID: window), to: $1) }
        session.terminals.liveTitle = { [weak host] in host?.liveTitle(of: AttachmentHandle(surfaceID: $0, windowID: window)) }
        return Fixture(host: host, configs: configs, controller: controller, origin: origin, session: session)
    }

    private func close(_ fixture: Fixture) {
        fixture.controller.closeTabImmediately(registerRedo: false)
    }

    /// A new terminal row, as ⌘T makes one. `command` stands in for what
    /// its shell runs; `/bin/cat` never titles itself, so only the test
    /// does. `waiting`: once `command` ends, Ghostty waits for a key.
    private func newShell(_ fixture: Fixture, running command: String? = nil, waiting: Bool = false) throws -> AttachmentHandle {
        let requestID = UUID()
        if command != nil || waiting {
            var config = Ghostty.SurfaceConfiguration()
            config.command = command
            config.waitAfterCommand = waiting
            fixture.configs.set(config, for: requestID)
        }
        return try fixture.host.showInContent(command: "", workingDirectory: nil, origin: fixture.origin, requestID: requestID)
    }

    private func attachAgent(_ fixture: Fixture) throws -> AttachmentHandle {
        try fixture.host.showInContent(command: Self.standIn, workingDirectory: nil, origin: fixture.origin, requestID: UUID())
    }

    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// The terminal titles itself `title`, and it has landed on the row,
    /// with nothing Ghostty sets on start-up still to come.
    private func titled(_ view: Ghostty.SurfaceView, _ title: String, in fixture: Fixture, _ shell: AttachmentHandle) async throws {
        await settle()
        view.setTitle(title)
        try #require(await eventually { fixture.label(shell) == title })
    }

    /// Longer than Ghostty's 75 ms title coalescing, so a title the
    /// terminal set has landed (or been held back) by then.
    private func settle() async { try? await Task.sleep(for: .milliseconds(250)) }

    // MARK: Rename

    @Test func renameSetsTheRowTitleAndSticks() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture, running: Self.standIn)
        let view = try #require(fixture.view(shell))
        // What `TerminalView` reports once the shell has focus.
        fixture.controller.focusedSurfaceDidChange(to: view)
        try await titled(view, "~/w", in: fixture, shell)

        fixture.terminals.rename(shell.surfaceID, to: "build")

        #expect(await eventually { fixture.label(shell) == "build" }, "the row")
        #expect(await eventually { fixture.controller.window?.title == "build" }, "the window")
        #expect(view.leoPaneName == "build", "a close confirm")
        #expect(view.leoTitleIsUserSet)

        view.setTitle("~/x")
        await settle()

        #expect(view.title == "build", "the terminal's own title doesn't replace it")
        #expect(fixture.label(shell) == "build")
        #expect(fixture.controller.window?.title == "build")
        #expect(fixture.terminals.liveTitle(shell.surfaceID) == "~/x", "what clearing it restores")
    }

    @Test(arguments: ["", "  ", "\n"])
    func anEmptyNameRestoresTheLiveTitle(_ blank: String) async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture, running: Self.standIn)
        let view = try #require(fixture.view(shell))
        // Past any title Ghostty sets as the surface starts up.
        try await titled(view, "~/w", in: fixture, shell)
        fixture.terminals.rename(shell.surfaceID, to: "build")
        view.setTitle("~/x")
        await settle()
        try #require(fixture.label(shell) == "build")

        fixture.terminals.rename(shell.surfaceID, to: blank)

        #expect(await eventually { fixture.label(shell) == "~/x" }, "\(fixture.label(shell) ?? "nil")")
        #expect(!view.leoTitleIsUserSet)
        view.setTitle("~/y")
        #expect(await eventually { fixture.label(shell) == "~/y" }, "it follows the terminal again")
    }

    /// Renaming twice and then clearing restores the terminal's own title,
    /// not the first name.
    @Test func clearingASecondNameRestoresTheLiveTitle() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture, running: Self.standIn)
        let view = try #require(fixture.view(shell))
        view.setTitle("~/x")
        #expect(await eventually { fixture.label(shell) == "~/x" })

        fixture.terminals.rename(shell.surfaceID, to: "build")
        fixture.terminals.rename(shell.surfaceID, to: "test")
        #expect(await eventually { fixture.label(shell) == "test" })
        fixture.terminals.rename(shell.surfaceID, to: "")

        #expect(await eventually { fixture.label(shell) == "~/x" })
    }

    /// Blank on a row never renamed leaves the terminal's own title be.
    @Test func anEmptyNameOnAnUnrenamedRowKeepsItsTitle() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture, running: Self.standIn)
        let view = try #require(fixture.view(shell))
        view.setTitle("~/x")
        #expect(await eventually { fixture.label(shell) == "~/x" })

        fixture.terminals.rename(shell.surfaceID, to: "")
        await settle()

        #expect(fixture.label(shell) == "~/x")
        #expect(!view.leoTitleIsUserSet)
    }

    /// B-082: a renamed row's pane closing beside a plain shell hands the
    /// row on; the name stays with the closed surface, and the row reads
    /// the shell carrying it on by its own title.
    @Test func aRowCarriedOnReadsItsHeirsOwnTitle() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newShell(fixture, running: Self.standIn)
        let split = try fixture.host.openSplit(
            command: "", workingDirectory: nil, origin: fixture.origin,
            sourceSurface: row.surfaceID, direction: .right, requestID: UUID()
        )
        let splitView = try #require(fixture.view(split))
        splitView.setTitle("~/heir")
        fixture.terminals.rename(row.surfaceID, to: "build")
        #expect(await eventually { fixture.label(row) == "build" })

        let rowView = try #require(fixture.view(row))
        fixture.controller.closeSurface(try #require(fixture.controller.surfaceTree.root?.node(view: rowView)), withConfirmation: false)

        #expect(await eventually { fixture.terminals.rows.map(\.id) == [split.surfaceID] })
        #expect(await eventually { fixture.label(split) != nil && fixture.label(split) != "build" }, "the heir's own title")
        #expect(!splitView.leoTitleIsUserSet)
    }

    @Test func renamingAHiddenRowRetitlesItWithoutShowingIt() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let hidden = try newShell(fixture, running: Self.standIn)
        let shown = try newShell(fixture, running: Self.standIn)
        let shownView = try #require(fixture.view(shown))
        try #require(!fixture.host.isShown(hidden))

        fixture.terminals.rename(hidden.surfaceID, to: "build")

        #expect(await eventually { fixture.label(hidden) == "build" })
        #expect(fixture.shown().count == 1 && fixture.shown().first === shownView, "what the window shows is untouched")
        #expect(fixture.terminals.selection == shown.surfaceID, "the selection doesn't move")
        #expect(!fixture.host.isShown(hidden))
    }

    @Test func renameStripsControlCharacters() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture, running: Self.standIn)
        let view = try #require(fixture.view(shell))

        fixture.terminals.rename(shell.surfaceID, to: "  a\nb\u{7}\u{1B} ")

        #expect(await eventually { fixture.label(shell) == "ab" })
        #expect(view.title == "ab")
    }

    /// Only a terminal row is renamed here: an agent's name is the
    /// daemon's.
    @Test func renamingAnAgentDoesNothing() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let agent = try attachAgent(fixture)
        let view = try #require(fixture.view(agent))

        fixture.host.renameTerminal(agent, to: "build")

        #expect(!view.leoTitleIsUserSet)
        #expect(view.title != "build")
    }

    // MARK: Persistence (the surface's restorable encoding)

    /// A shell row's custom title persists wherever its surface is
    /// restored: Ghostty's restorable encoding carries it, user-set, so it
    /// still sticks over the restored terminal's own titles.
    @Test(arguments: [true, false])
    func customTitleRoundTripsThroughSurfaceRestoration(_ renamed: Bool) async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture, running: Self.standIn)
        let view = try #require(fixture.view(shell))
        if renamed { fixture.terminals.rename(shell.surfaceID, to: "build") } else { view.setTitle("~/x") }
        #expect(await eventually { fixture.label(shell) == (renamed ? "build" : "~/x") })

        let data = try JSONEncoder().encode(view)
        let restored = try JSONDecoder().decode(Ghostty.SurfaceView.self, from: data)

        #expect(restored.leoTitleIsUserSet == renamed)
        guard renamed else { return }
        #expect(restored.title == "build")
        restored.setTitle("~/y")
        await settle()
        #expect(restored.title == "build", "it still sticks")
    }

    // MARK: Close

    /// Close on a busy row asks as ⌘W does, naming it; Cancel keeps it.
    @Test(.timeLimit(.minutes(1)), arguments: ["shown", "hidden"])
    func closeFromMenuOnABusyRowAsks(_ state: String) async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let window = try #require(fixture.controller.window)
        let busy = try newShell(fixture, running: Self.standIn)
        let busyView = try #require(fixture.view(busy))
        try #require(await eventually { busyView.needsConfirmQuit }, "its process is running")
        let other = state == "hidden" ? try newShell(fixture) : nil
        // A sheet reliably attaches only to a window on screen.
        window.orderFront(nil)
        let sheets = SheetWatch()
        let watcher = Task { await sheets.cancelAny(on: window) }
        defer { watcher.cancel() }

        await fixture.host.closeTerminalFromMenu(busy)

        #expect(await eventually { sheets.sawSheet }, "it asks first")
        #expect(sheets.texts.contains(LeoCloseConfirmation.messageText(closing: [busyView.leoPaneName])))
        #expect(sheets.texts.contains(LeoCloseConfirmation.rowInformativeText))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(fixture.terminals.contains(busy.surfaceID), "cancelled: the row stays")
        #expect(fixture.host.isOpen(busy))
        #expect(fixture.host.isShown(busy) == (other == nil))
    }

    /// Confirmed, a hidden busy row closes; what the window shows stays.
    @Test(.timeLimit(.minutes(1)))
    func closeFromMenuOnAHiddenBusyRowClosesOnceConfirmed() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let window = try #require(fixture.controller.window)
        let busy = try newShell(fixture, running: Self.standIn)
        let busyView = try #require(fixture.view(busy))
        try #require(await eventually { busyView.needsConfirmQuit }, "its process is running")
        let shown = try newShell(fixture)
        let shownView = try #require(fixture.view(shown))
        window.orderFront(nil)
        let confirm = Task {
            while !Task.isCancelled {
                if let sheet = window.attachedSheet { return window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { confirm.cancel() }

        await fixture.host.closeTerminalFromMenu(busy)

        #expect(await eventually { !fixture.terminals.contains(busy.surfaceID) })
        #expect(!fixture.host.isOpen(busy))
        #expect(fixture.shown().count == 1 && fixture.shown().first === shownView)
        #expect(fixture.terminals.selection == shown.surfaceID)
    }

    /// Nothing running (its command ended): the shown row closes without
    /// asking, and its neighbour shows in its place.
    @Test(.timeLimit(.minutes(1)))
    func closeFromMenuOnAnIdleShownRowClosesWithoutAsking() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let window = try #require(fixture.controller.window)
        let first = try newShell(fixture)
        let neighbour = try #require(fixture.view(first))
        let idle = try newShell(fixture, running: "/usr/bin/true", waiting: true)
        let idleView = try #require(fixture.view(idle))
        try #require(await eventually { !idleView.needsConfirmQuit }, "its command ended")
        window.orderFront(nil)
        let sheets = SheetWatch()
        let watcher = Task { await sheets.cancelAny(on: window) }
        defer { watcher.cancel() }

        await fixture.host.closeTerminalFromMenu(idle)

        #expect(await eventually { !fixture.terminals.contains(idle.surfaceID) })
        #expect(fixture.shown().first === neighbour, "the neighbour's own surface")
        #expect(fixture.terminals.selection == first.surfaceID)
        #expect(!sheets.sawSheet)
    }

    /// A hidden shell at its prompt closes without asking; what the window
    /// shows stays.
    @Test(.timeLimit(.minutes(1)))
    func closeFromMenuOnAnIdleHiddenRowClosesWithoutAsking() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let window = try #require(fixture.controller.window)
        let idle = try newShell(fixture)
        let idleView = try #require(fixture.view(idle))
        try #require(await eventually(.seconds(15)) { !idleView.needsConfirmQuit }, "the shell reached its prompt")
        let shown = try newShell(fixture, running: Self.standIn)
        let shownView = try #require(fixture.view(shown))
        window.orderFront(nil)
        let sheets = SheetWatch()
        let watcher = Task { await sheets.cancelAny(on: window) }
        defer { watcher.cancel() }

        await fixture.host.closeTerminalFromMenu(idle)

        #expect(await eventually { !fixture.terminals.contains(idle.surfaceID) })
        #expect(!fixture.host.isOpen(idle))
        #expect(fixture.shown().count == 1 && fixture.shown().first === shownView)
        #expect(!sheets.sawSheet)
    }

    /// Fix round 1: no hidden row can hold a busy split for Close to kill
    /// unasked. Switching away from a row with a busy shell split beside it
    /// asks first (cancelled: it all stays shown); once confirmed, the
    /// switch closes the split and the row together -- nothing is kept, so
    /// there is no hidden row left for its menu to close.
    @Test(.timeLimit(.minutes(1)))
    func aRowWithABusySplitBesideItIsNeverKeptForCloseToKill() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let window = try #require(fixture.controller.window)
        let row = try newShell(fixture)
        let busyConfig = UUID()
        var config = Ghostty.SurfaceConfiguration()
        config.command = Self.standIn
        fixture.configs.set(config, for: busyConfig)
        let split = try fixture.host.openSplit(
            command: "", workingDirectory: nil, origin: fixture.origin,
            sourceSurface: row.surfaceID, direction: .right, requestID: busyConfig
        )
        let splitView = try #require(fixture.view(split))
        try #require(await eventually { splitView.needsConfirmQuit }, "the split's process is running")
        window.orderFront(nil)
        let sheets = SheetWatch()
        let watcher = Task { await sheets.cancelAny(on: window) }
        defer { watcher.cancel() }

        let mayReplace = await fixture.host.confirmReplacingContent(origin: fixture.origin)

        #expect(sheets.sawSheet, "switching away asks first")
        #expect(sheets.texts.contains(LeoContentReplacement.informativeText), "the switch's own confirm")
        #expect(!mayReplace)
        #expect(fixture.host.isShown(row) && fixture.host.isShown(split), "cancelled: both stay shown")

        // Confirmed: the switch closes them together.
        _ = try attachAgent(fixture)

        #expect(fixture.host.hiddenSurfaces(in: fixture.windowID).isEmpty, "nothing is kept")
        #expect(!fixture.host.isOpen(row) && !fixture.host.isOpen(split))
        #expect(!fixture.terminals.contains(row.surfaceID), "no hidden row is left to close")
        await fixture.host.closeTerminalFromMenu(row)
        #expect(!fixture.host.isOpen(split))
    }

    // MARK: Split

    /// What a split beside the row's shell starts from: ⌘D's inherited
    /// configuration (its working directory), shown or hidden.
    @Test func aRowsSplitConfigurationIsItsShells() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let shell = try newShell(fixture, running: Self.standIn)
        let agent = try attachAgent(fixture)

        #expect(fixture.host.splitConfiguration(for: shell) != nil, "hidden")
        #expect(fixture.host.splitConfiguration(for: agent) == nil, "not a terminal row")
        #expect(fixture.host.splitConfiguration(for: AttachmentHandle(surfaceID: UUID(), windowID: fixture.windowID)) == nil)
    }
}
