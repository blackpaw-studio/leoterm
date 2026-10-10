import Foundation
import Testing

@testable import Ghostty

/// B-274: each sidebar row keeps its own editor and browser in its window.
/// Switching rows switches panes; a row's pane lives until the row goes or
/// the window closes, and nothing with unsaved edits goes without asking.
@MainActor
struct LeoRowPanesTests {
    private static let agentA = LeoRowKey.agent(LeoAgentIdentity(host: .local, name: "alpha"))
    private static let agentB = LeoRowKey.agent(LeoAgentIdentity(host: .local, name: "beta"))

    /// What the panes asked, and what to answer.
    private final class Prompts {
        var asked: [(file: String, row: String?)] = []
        var answer: LeoUnsavedChangesChoice = .cancel
    }

    private func makePanes(
        _ prompts: Prompts = Prompts(),
        access: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess = { _ in LeoFileAccessor.local() }
    ) -> LeoRowPanes {
        let panes = LeoRowPanes(makeAccess: access) { document, row in
            prompts.asked.append((document.displayName, row))
            return prompts.answer
        }
        panes.rowName = { key in key == Self.agentA ? "alpha" : key == Self.agentB ? "beta" : nil }
        return panes
    }

    private func agent(_ name: String, _ workspace: String) -> LeoEditorAgentContext {
        LeoEditorAgentContext(host: .local, name: name, workspace: workspace)
    }

    @Test
    func eachRowKeepsItsOwnDocument() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let panes = makePanes()
            panes.activate(Self.agentA)
            try await panes.active.editor.open(LeoEditorFileID(host: .local, path: path))
            let document = try #require(panes.active.editor.document)
            document.edit("a, edited")

            panes.activate(Self.agentB)
            #expect(panes.active.editor.document == nil)

            panes.activate(Self.agentA)
            #expect(panes.active.editor.document === document)
            #expect(document.isDirty)
            #expect(document.text == "a, edited")
            panes.active.editor.document?.edit("a")
            await panes.releaseAll()
        }
    }

    @Test
    func eachRowsBrowserKeepsItsRootAndExpansion() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let rootA = try sandbox.directory("a/src").replacingOccurrences(of: "/src", with: "")
            let rootB = try sandbox.directory("b")
            try sandbox.file("a/src/main.swift", "")
            let panes = makePanes()
            panes.activate(Self.agentA)
            await panes.active.browser.open(agent("alpha", rootA))
            await panes.active.browser.expand(rootA + "/src")

            panes.activate(Self.agentB)
            await panes.active.browser.open(agent("beta", rootB))
            #expect(panes.active.browser.root?.path == rootB)
            #expect(panes.active.browser.expanded.isEmpty)

            panes.activate(Self.agentA)
            #expect(panes.active.browser.root?.path == rootA)
            #expect(panes.active.browser.expanded == [rootA + "/src"])
            await panes.releaseAll()
        }
    }

    @Test
    func browserOpensFilesInItsOwnRowsEditor() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let panes = makePanes()
            let paneA = panes.pane(for: Self.agentA)
            let paneB = panes.pane(for: Self.agentB)
            await paneA.browser.open(agent("alpha", sandbox.root))

            await paneA.browser.openFile(path)

            #expect(paneA.editor.document?.fileID.path == path)
            #expect(paneB.editor.document == nil)
            await panes.releaseAll()
        }
    }

    @Test
    func closingACleanRowReleasesItsAccess() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let closes = LeoCloseCounter()
            let panes = makePanes(access: { _ in LeoCloseCountingAccess(base: LeoFileAccessor.local(), counter: closes) })
            try await panes.pane(for: Self.agentA).editor.open(LeoEditorFileID(host: .local, path: path))

            panes.rowRemoved(Self.agentA)

            #expect(panes.existingPane(for: Self.agentA) == nil)
            #expect(await eventually { closes.count == 1 })
        }
    }

    @Test
    func closingADirtyRowAsks() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let prompts = Prompts()
            let panes = makePanes(prompts)
            panes.activate(Self.agentB)
            let paneA = panes.pane(for: Self.agentA)
            try await paneA.editor.open(LeoEditorFileID(host: .local, path: path))
            paneA.editor.document?.edit("edited")

            #expect(await panes.close(Self.agentA) == false)
            #expect(panes.existingPane(for: Self.agentA) === paneA)
            #expect(prompts.asked.map(\.row) == ["alpha"], "a pane not on screen is named by its row")

            prompts.answer = .discard
            #expect(await panes.close(Self.agentA))
            #expect(panes.existingPane(for: Self.agentA) == nil)
        }
    }

    @Test
    func rowRemovedWithoutAskingKeepsADirtyOrphanAndLeavingItAsks() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let prompts = Prompts()
            let panes = makePanes(prompts)
            let hidden = panes.pane(for: Self.agentB)
            try await hidden.editor.open(LeoEditorFileID(host: .local, path: path))
            hidden.editor.document?.edit("hidden edit")
            let shownKey = LeoRowKey.terminal(UUID())
            panes.activate(shownKey)
            try await panes.active.editor.open(LeoEditorFileID(host: .local, path: path))
            let shown = panes.active
            shown.editor.document?.edit("shown edit")

            // A hidden row's shell exits: its pane is kept, unreachable.
            panes.rowRemoved(Self.agentB)
            #expect(panes.existingPane(for: Self.agentB) == nil)
            #expect(panes.allEditors.contains { $0 === hidden.editor })
            #expect(panes.hasUnsavedEdits)

            // The shown row's shell exits: the start screen keeps its pane.
            panes.rowRemoved(shownKey)
            panes.activate(.startScreen)
            #expect(panes.active === shown)
            #expect(panes.isStartScreenOrphan)

            #expect(await panes.leaveOrphanedStartScreen() == false)
            #expect(panes.existingPane(for: .startScreen) === shown)
            prompts.answer = .discard
            #expect(await panes.leaveOrphanedStartScreen())
            #expect(panes.existingPane(for: .startScreen) == nil)
            #expect(!panes.isStartScreenOrphan)
            hidden.editor.document?.edit("a")
            await panes.releaseAll()
        }
    }

    @Test
    func rekeyCarriesThePaneToTheReplacementShell() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let panes = makePanes()
            let old = LeoRowKey.terminal(UUID())
            let new = LeoRowKey.terminal(UUID())
            panes.activate(old)
            let pane = panes.active
            try await pane.editor.open(LeoEditorFileID(host: .local, path: path))

            panes.rekey(old, to: new)

            #expect(panes.existingPane(for: old) == nil)
            #expect(panes.existingPane(for: new) === pane)
            #expect(panes.activeKey == new)
            await panes.releaseAll()
        }
    }

    @Test
    func hiddenPaneConfirmPresentsOnTheSessionWindow() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let other = try sandbox.file("b.txt", "b")
            let prompts = Prompts()
            prompts.answer = .discard
            let panes = makePanes(prompts)
            let pane = panes.pane(for: Self.agentA)
            // Built and never on screen: its view has no window.
            _ = LeoEditorPaneViewController(model: pane.editor)
            try await pane.editor.open(LeoEditorFileID(host: .local, path: path))
            pane.editor.document?.edit("edited")

            try await pane.editor.open(LeoEditorFileID(host: .local, path: other))

            #expect(prompts.asked.map(\.file) == ["a.txt"])
            #expect(pane.editor.document?.fileID.path == other)
            await panes.releaseAll()
        }
    }

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

/// Counts how many times file access was closed.
@MainActor final class LeoCloseCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

/// A `LeoFileAccess` that reports each `close` to a counter.
struct LeoCloseCountingAccess: LeoFileAccess {
    let base: any LeoFileAccess
    let counter: LeoCloseCounter

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }
    func close() async {
        await counter.record()
        await base.close()
    }
}
