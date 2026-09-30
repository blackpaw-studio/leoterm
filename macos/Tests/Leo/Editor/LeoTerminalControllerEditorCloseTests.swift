import AppKit
import Foundation
import Testing

@testable import Ghostty

/// `TerminalController`'s close paths with unsaved editor edits (B-004,
/// B-022): a close that can't ask keeps the tab, and ⌘W in the terminal
/// asks first. Drives real controllers, so it needs the app's real
/// `Ghostty.App` (via `AppDelegate`) and bails out without it, like
/// `GhosttyAttachTabHostRebirthTests`.
@MainActor
struct LeoTerminalControllerEditorCloseTests {
    /// A placeholder window and its session, its editor open on `a.txt`
    /// (edited when `editing`), prompts answered with `answer`.
    @MainActor private struct Tab {
        let controller: TerminalController
        let session: LeoWindowSession
        var editor: LeoEditorPaneModel { session.editor }
    }

    private func makeTab(in sandbox: LeoFileSandbox, editing: Bool) async throws -> Tab? {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return nil }
        let controller = TerminalController.leoNewPlaceholderWindow(ghostty)
        let session = try #require(controller.leoSession)
        try await session.editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
        if editing { session.editor.document?.edit("edited") }
        // The pane's view installs its own prompt when it's built.
        await nextTurn()
        return Tab(controller: controller, session: session)
    }

    /// Gives the tab a live terminal, as an attached agent's.
    private func fill(_ tab: Tab) throws {
        let host = GhosttyAttachTabHost(
            registry: try #require((NSApp.delegate as? AppDelegate)?.leoRuntime.registry), requestConfigStore: LeoRequestConfigStore())
        _ = try host.fillPlaceholder(command: "", workingDirectory: nil, origin: tab.session.id, surfaceID: nil, requestID: UUID())
    }

    private func tearDown(_ tab: Tab) async {
        tab.editor.confirmUnsaved = { _ in .discard }
        await tab.editor.close()
        tab.controller.window?.close()
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: leoKeepForUnsavedEdits

    /// With unsaved edits the tab stays: its terminal goes (the start
    /// screen replaces it) and the window with its editor is kept.
    @Test func unsavedEditsKeepTheTabAndDropItsTerminal() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            guard let tab = try await makeTab(in: sandbox, editing: true) else { return }
            try fill(tab)
            try #require(!tab.controller.surfaceTree.isEmpty)

            #expect(tab.controller.leoKeepForUnsavedEdits())

            #expect(tab.controller.surfaceTree.isEmpty)
            await nextTurn()
            #expect(tab.controller.window?.isVisible == true)
            #expect(tab.editor.document?.isDirty == true)
            await tearDown(tab)
        }
    }

    @Test func withoutUnsavedEditsNothingIsKept() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            guard let tab = try await makeTab(in: sandbox, editing: false) else { return }
            try fill(tab)

            #expect(!tab.controller.leoKeepForUnsavedEdits())

            #expect(!tab.controller.surfaceTree.isEmpty)
            await tearDown(tab)
        }
    }

    /// B-071: the start screen kept for unsaved edits is one ⌘Z doesn't
    /// cross either. Agent A with a split S; ⌘W A; S exits, so the start
    /// screen shows beside the editor; a shell is chosen there. ⌘Z then
    /// would replay [A, S] over that shell and drop it without asking.
    @Test func undoAfterTheStartScreenKeptForUnsavedEditsLeavesTheNewShellAlone() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            guard let tab = try await makeTab(in: sandbox, editing: true) else { return }
            let controller = tab.controller
            let undoManager = try #require(controller.undoManager)
            undoManager.removeAllActions(withTarget: controller)
            undoManager.leoRemoveActionsTestsCanReplay(ghostty: controller.ghostty)
            let host = GhosttyAttachTabHost(
                registry: try #require((NSApp.delegate as? AppDelegate)?.leoRuntime.registry), requestConfigStore: LeoRequestConfigStore())
            let agent = try host.fillPlaceholder(
                command: "/bin/cat", workingDirectory: nil, origin: tab.session.id, surfaceID: nil, requestID: UUID())
            // ⌘D kept out of undo: typed, it is its own undo group, but the
            // test host never ends one (`groupsByEvent`), so ⌘Z would undo
            // it with ⌘W's.
            undoManager.disableUndoRegistration()
            let split = try host.openSplit(
                command: "", workingDirectory: nil, origin: tab.session.id,
                sourceSurface: agent.surfaceID, direction: .right, requestID: UUID())
            undoManager.enableUndoRegistration()
            let agentView = try #require(controller.surfaceTree.first { $0.id == agent.surfaceID })
            controller.closeSurface(try #require(controller.surfaceTree.root?.node(view: agentView)), withConfirmation: false)
            let splitView = try #require(controller.surfaceTree.first { $0.id == split.surfaceID })
            controller.closeSurface(try #require(controller.surfaceTree.root?.node(view: splitView)), withConfirmation: false)
            try #require(controller.surfaceTree.isEmpty, "the start screen, kept for the editor's edits")
            let shell = try host.fillPlaceholder(
                command: "", workingDirectory: nil, origin: tab.session.id, surfaceID: nil, requestID: UUID())

            undoManager.undo()

            #expect(Array(controller.surfaceTree).map(\.id) == [shell.surfaceID], "the chosen shell stays")
            #expect(host.isShown(shell))
            await tearDown(tab)
        }
    }

    // MARK: Closes that can't ask

    /// `closeTabImmediately` and `closeWindowImmediately` (the terminal's
    /// process exited, AppleScript, undo) keep a tab with unsaved edits,
    /// and close one without.
    @Test(arguments: ["closeTabImmediately", "closeWindowImmediately"])
    func aCloseThatCantAskKeepsATabWithUnsavedEdits(_ close: String) async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            for editing in [true, false] {
                guard let tab = try await makeTab(in: sandbox, editing: editing) else { return }
                let window = try #require(tab.controller.window)
                try #require(window.isVisible)

                if close == "closeTabImmediately" {
                    tab.controller.closeTabImmediately()
                } else {
                    tab.controller.closeWindowImmediately()
                }
                await nextTurn()

                #expect(window.isVisible == editing, "\(close), editing: \(editing)")
                #expect((tab.editor.document?.isDirty == true) == editing)
                await tearDown(tab)
            }
        }
    }

    // MARK: ⌘W

    /// ⌘W in the terminal, when it would close the tab, asks about the
    /// editor's unsaved edits first; Cancel keeps everything.
    @Test(.timeLimit(.minutes(1)))
    func commandWAsksAboutUnsavedEditsFirst() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            guard let tab = try await makeTab(in: sandbox, editing: true) else { return }
            var asked: [String] = []
            tab.editor.confirmUnsaved = { document in
                asked.append(document.displayName)
                return .cancel
            }

            tab.controller.close(tab.controller)

            #expect(await eventually { !asked.isEmpty })
            await nextTurn()
            #expect(asked == ["a.txt"])
            #expect(tab.controller.window?.isVisible == true)
            #expect(tab.editor.document?.isDirty == true)
            await tearDown(tab)
        }
    }

    /// Don't Save lets ⌘W go on: the edits are dropped, then the close runs.
    @Test(.timeLimit(.minutes(1)))
    func commandWGoesOnAfterDontSave() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            guard let tab = try await makeTab(in: sandbox, editing: true) else { return }
            var asked = 0
            tab.editor.confirmUnsaved = { _ in
                asked += 1
                return .discard
            }

            tab.controller.close(tab.controller)

            #expect(await eventually { tab.editor.document == nil })
            #expect(asked == 1)
            #expect(try sandbox.contents("a.txt") == "a")
            await tearDown(tab)
        }
    }
}
