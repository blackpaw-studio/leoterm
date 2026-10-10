import AppKit
import Testing

@testable import Ghostty

/// B-274: closing a row closes its editor pane, asking first when it has
/// unsaved edits; a close that can't ask keeps the pane. Drives a real
/// `TerminalController` with terminal rows, so it needs the app's real
/// `Ghostty.App` (like `LeoTerminalRowsIntegrationTests`). Windows are
/// built but never shown.
@MainActor @Suite(.serialized) struct LeoRowPaneCloseTests {
    @MainActor private struct Fixture {
        let host: GhosttyAttachContentHost
        let controller: TerminalController
        /// Where requests are routed from (the host's registry entry).
        let origin: LeoWindowID
        /// The window's own session: its sidebar and panes.
        let session: LeoWindowSession
        var panes: LeoRowPanes { session.panes }
        var terminals: LeoWindowTerminals { session.terminals }
    }

    /// What a pane's prompt was asked, and its answer.
    @MainActor private final class Prompts {
        var asked: [String] = []
        var answer: LeoUnsavedChangesChoice = .cancel
    }

    private func makeFixture() throws -> Fixture {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty, "these tests need the app's Ghostty.App")
        let app = try #require(ghostty.app)
        let controller = TerminalController(ghostty, withSurfaceTree: SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil)))
        let registry = LeoWindowSessionRegistry()
        let origin = registry.makeSession(window: controller.window, controller: controller, defaults: LeoInMemoryDefaults()).id
        let session = try #require(controller.leoSession)
        let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: LeoRequestConfigStore()) { .init(isActive: false, keyWindow: nil) }
        // What `LeoRuntime` wires for the app's own sessions.
        let sessionID = session.id
        session.terminals.closeRequested = { [weak host] in host?.closeTerminal(AttachmentHandle(surfaceID: $0, windowID: sessionID)) }
        return Fixture(host: host, controller: controller, origin: origin, session: session)
    }

    private func newShell(_ fixture: Fixture) throws -> AttachmentHandle {
        let shell = try fixture.host.showInContent(command: "", workingDirectory: nil, origin: fixture.origin, requestID: UUID())
        fixture.panes.activate(.terminal(shell.surfaceID))
        return shell
    }

    /// `shell`'s pane, open on `a.txt` and edited, its prompt answered from `prompts`.
    private func editInPane(of shell: AttachmentHandle, _ fixture: Fixture, _ sandbox: LeoFileSandbox, _ prompts: Prompts) async throws -> LeoRowPane {
        let pane = fixture.panes.pane(for: .terminal(shell.surfaceID))
        try await pane.tabs.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
        pane.tabs.document?.edit("edited")
        pane.tabs.confirmUnsaved = { document in
            prompts.asked.append(document.displayName)
            return prompts.answer
        }
        return pane
    }

    private func tearDown(_ fixture: Fixture) async {
        for editor in fixture.panes.allEditors { editor.confirmUnsaved = { _ in .discard } }
        await fixture.panes.releaseAll()
        fixture.controller.closeTabImmediately(registerRedo: false)
    }

    private func turns(limit: Int = 50, until condition: () -> Bool) async -> Bool {
        for _ in 0 ..< limit where !condition() {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        return condition()
    }

    @Test func exitOfARowWithADirtyPaneShowsTheStartScreenWithIt() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let fixture = try makeFixture()
            let neighbour = try newShell(fixture)
            let closing = try newShell(fixture)
            let pane = try await editInPane(of: closing, fixture, sandbox, Prompts())

            // `exit`: nothing can ask first.
            fixture.host.closeTerminal(closing)
            fixture.panes.activate(.startScreen)

            #expect(fixture.controller.surfaceTree.isEmpty, "the start screen, not the neighbour")
            #expect(fixture.terminals.rows.map(\.id) == [neighbour.surfaceID])
            #expect(fixture.panes.active === pane)
            #expect(fixture.panes.isStartScreenOrphan)
            #expect(pane.tabs.document?.isDirty == true)
            await tearDown(fixture)
        }
    }

    @Test func terminalRowCloseAsksAboutItsPaneAndCancelKeepsTheRow() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let fixture = try makeFixture()
            let shell = try newShell(fixture)
            let prompts = Prompts()
            let pane = try await editInPane(of: shell, fixture, sandbox, prompts)

            // ⌘W on the row's shell, then Close on its menu.
            #expect(fixture.controller.leoDeferCloseOfLastSplit { Issue.record("Cancel must not close") })
            #expect(await turns { prompts.asked.count == 1 })
            await fixture.host.closeTerminalFromMenu(shell)

            #expect(prompts.asked == ["a.txt", "a.txt"])
            #expect(fixture.terminals.contains(shell.surfaceID))
            #expect(fixture.panes.existingPane(for: .terminal(shell.surfaceID)) === pane)

            prompts.answer = .discard
            var retried = false
            #expect(fixture.controller.leoDeferCloseOfLastSplit { retried = true })
            #expect(await turns { retried })
            #expect(fixture.panes.existingPane(for: .terminal(shell.surfaceID)) == nil)
            await tearDown(fixture)
        }
    }

    /// ⌘W on the row's shell with an agent split beside it: no plain shell
    /// carries the row on, so the row goes -- its pane is asked about first.
    @Test func closingARowsPaneBesideASplitAsksAboutItsPane() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let fixture = try makeFixture()
            let shell = try newShell(fixture)
            _ = try fixture.host.openSplit(
                command: "/bin/cat", workingDirectory: nil, origin: fixture.origin,
                sourceSurface: shell.surfaceID, direction: .right, requestID: UUID())
            let prompts = Prompts()
            let pane = try await editInPane(of: shell, fixture, sandbox, prompts)
            let view = try #require(fixture.controller.surfaceTree.first { $0.id == shell.surfaceID })
            let node = try #require(fixture.controller.surfaceTree.root?.node(view: view))

            fixture.controller.closeSurface(node, withConfirmation: true)
            #expect(await turns { prompts.asked.count == 1 })

            #expect(prompts.asked == ["a.txt"])
            #expect(fixture.controller.surfaceTree.contains(view), "Cancel keeps the row's shell")
            #expect(fixture.terminals.contains(shell.surfaceID))
            #expect(fixture.panes.existingPane(for: .terminal(shell.surfaceID)) === pane)

            prompts.answer = .discard
            fixture.controller.closeSurface(node, withConfirmation: true)
            #expect(await turns { fixture.panes.existingPane(for: .terminal(shell.surfaceID)) == nil })
            #expect(pane.tabs.document == nil, "closed through its prompt, not kept as an orphan")
            if let window = fixture.controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
            await tearDown(fixture)
        }
    }

    @Test func aDirtyHiddenRowKeepsTheWindowAndCloseAsksAboutIt() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let fixture = try makeFixture()
            let hidden = try newShell(fixture)
            let prompts = Prompts()
            _ = try await editInPane(of: hidden, fixture, sandbox, prompts)
            _ = try newShell(fixture)
            let window = try #require(fixture.controller.window)

            #expect(fixture.controller.leoHasUnsavedEdits)
            var goesAhead: Bool?
            #expect(TerminalController.leoDeferClose(of: [window]) { goesAhead = true })
            #expect(await turns { !prompts.asked.isEmpty })

            #expect(prompts.asked == ["a.txt"])
            #expect(goesAhead == nil, "Cancel keeps the window")
            await tearDown(fixture)
        }
    }
}
