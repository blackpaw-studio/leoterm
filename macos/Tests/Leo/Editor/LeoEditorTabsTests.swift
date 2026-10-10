import Foundation
import Testing

@testable import Ghostty

/// B-273: a row's editor pane holds one tab per open file. Opening adds a
/// tab or selects the file's own; a background open (a surfaced file)
/// never asks for focus or takes the selection from the user; closing a
/// tab with unsaved edits asks first.
@MainActor
struct LeoEditorTabsTests {
    private final class Prompts {
        var asked: [String] = []
        /// The selected tab's file when each prompt came up.
        var selectedWhenAsked: [String?] = []
        var answers: [LeoUnsavedChangesChoice]
        init(_ answers: [LeoUnsavedChangesChoice]) { self.answers = answers }
    }

    private func makeTabs(
        answering answers: [LeoUnsavedChangesChoice] = [.cancel],
        access: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess = { _ in LeoFileAccessor.local() }
    ) -> (LeoEditorTabs, Prompts) {
        let prompts = Prompts(answers)
        let tabs = LeoEditorTabs(makeAccess: access)
        tabs.confirmUnsaved = { [weak tabs] document in
            prompts.asked.append(document.displayName)
            prompts.selectedWhenAsked.append(tabs?.document?.displayName)
            return prompts.answers.count > 1 ? prompts.answers.removeFirst() : prompts.answers[0]
        }
        return (tabs, prompts)
    }

    private func file(_ path: String) -> LeoEditorFileID { LeoEditorFileID(host: .local, path: path) }

    private func names(_ tabs: LeoEditorTabs) -> [String] { tabs.tabs.compactMap { $0.document?.displayName } }

    @Test
    func opensEachFileInItsOwnTab() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let (tabs, _) = makeTabs()
            try await tabs.open(file(try sandbox.file("a.txt", "a")))
            tabs.document?.edit("a, edited")

            #expect(try await tabs.open(file(try sandbox.file("b.txt", "b"))) == .opened)

            #expect(names(tabs) == ["a.txt", "b.txt"])
            #expect(tabs.document?.displayName == "b.txt")
            #expect(tabs.tabs.first?.document?.text == "a, edited")
            await tabs.release()
        }
    }

    @Test
    func reopeningAnOpenFileSelectsItsTab() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let (tabs, prompts) = makeTabs()
            let a = file(try sandbox.file("a.txt", "a"))
            try await tabs.open(a)
            tabs.document?.edit("a, edited")
            try await tabs.open(file(try sandbox.file("b.txt", "b")))

            #expect(try await tabs.open(a) == .alreadyOpen)

            #expect(names(tabs) == ["a.txt", "b.txt"])
            #expect(tabs.document?.displayName == "a.txt")
            #expect(tabs.document?.text == "a, edited")
            #expect(prompts.asked.isEmpty)
            await tabs.release()
        }
    }

    @Test
    func newestBackgroundOpenStaysSelectedWhenReadsFinishOutOfOrder() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let a = try sandbox.file("a.txt", "a"), b = try sandbox.file("b.txt", "b")
            let reads = LeoGatedReads([a, b])
            let (tabs, _) = makeTabs(access: reads.makeAccess)
            let older = Task { try await tabs.open(file(a), mode: .background) }
            await reads.waitUntilReading(a)
            let newer = Task { try await tabs.open(file(b), mode: .background) }
            await reads.waitUntilReading(b)

            reads.release(b)
            _ = try await newer.value
            reads.release(a)
            _ = try await older.value

            #expect(Set(names(tabs)) == ["a.txt", "b.txt"])
            #expect(tabs.document?.displayName == "b.txt")
            await tabs.release()
        }
    }

    @Test
    func backgroundOpenLeavesUserSelection() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let b = try sandbox.file("b.txt", "b")
            let reads = LeoGatedReads([b])
            let (tabs, _) = makeTabs(access: reads.makeAccess)
            try await tabs.open(file(try sandbox.file("a.txt", "a")))
            try await tabs.open(file(try sandbox.file("c.txt", "c")))
            let background = Task { try await tabs.open(file(b), mode: .background) }
            await reads.waitUntilReading(b)

            tabs.select(try #require(tabs.tabs.first))
            reads.release(b)

            #expect(try await background.value == .opened)
            #expect(names(tabs) == ["a.txt", "c.txt", "b.txt"])
            #expect(tabs.document?.displayName == "a.txt")
            await tabs.release()
        }
    }

    @Test
    func backgroundOpenNeverRequestsFocus() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let (tabs, _) = makeTabs()
            let a = file(try sandbox.file("a.txt", "a"))

            try await tabs.open(a, mode: .background)
            try await tabs.open(file(try sandbox.file("b.txt", "b")), mode: .background)
            try await tabs.open(a, mode: .background)
            #expect(tabs.focusRequest == 0)
            #expect(tabs.document?.displayName == "a.txt")

            try await tabs.open(file(try sandbox.file("c.txt", "c")))
            #expect(tabs.focusRequest == 1)
            tabs.select(try #require(tabs.tabs.first))
            #expect(tabs.focusRequest == 2)
            tabs.selectNext()
            #expect(tabs.focusRequest == 2)
            await tabs.release()
        }
    }

    @Test
    func closingDirtyTabAsksFirst() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let (tabs, prompts) = makeTabs(answering: [.cancel, .discard])
            for name in ["a", "b", "c"] { try await tabs.open(file(try sandbox.file("\(name).txt", name))) }
            let b = tabs.tabs[1]
            tabs.select(b)
            b.document?.edit("b, edited")

            #expect(await tabs.closeTab(b) == false)
            #expect(names(tabs) == ["a.txt", "b.txt", "c.txt"])
            #expect(prompts.asked == ["b.txt"])

            #expect(await tabs.closeTab(b))
            #expect(names(tabs) == ["a.txt", "c.txt"])
            #expect(tabs.document?.displayName == "c.txt")

            #expect(await tabs.closeSelected())
            #expect(tabs.document?.displayName == "a.txt")
            await tabs.release()
        }
    }

    @Test
    func closeAllAsksEachDirtyTabSelectedInTurn() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let (tabs, prompts) = makeTabs(answering: [.discard, .cancel])
            for name in ["a", "b", "c"] { try await tabs.open(file(try sandbox.file("\(name).txt", name))) }
            tabs.tabs[0].document?.edit("a, edited")
            tabs.tabs[1].document?.edit("b, edited")

            #expect(await tabs.closeAll() == false)

            #expect(prompts.asked == ["a.txt", "b.txt"])
            #expect(prompts.selectedWhenAsked == ["a.txt", "b.txt"])
            #expect(names(tabs) == ["b.txt", "c.txt"])
            tabs.tabs[0].document?.edit("b")
            await tabs.release()
        }
    }

    /// Review fix 1: a tab added (and edited) while closeAll waits on a
    /// slow Save is asked about too, never dropped with its edits.
    @Test
    func closeAllAsksAboutATabAddedWhileItWaited() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let a = try sandbox.file("a.txt", "a")
            let writes = LeoGatedReads([], writes: [a])
            let (tabs, prompts) = makeTabs(answering: [.save, .cancel], access: writes.makeAccess)
            try await tabs.open(file(a))
            tabs.document?.edit("a, edited")
            let closing = Task { await tabs.closeAll() }
            await writes.waitUntil(.write, a)

            try await tabs.open(file(try sandbox.file("b.txt", "b")), mode: .background)
            let b = try #require(tabs.tab(for: file(sandbox.path("b.txt"))))
            b.document?.edit("b, edited")
            writes.release(.write, a)

            #expect(await closing.value == false)
            #expect(prompts.asked == ["a.txt", "b.txt"])
            #expect(names(tabs) == ["b.txt"])
            #expect(b.document?.text == "b, edited")
            b.document?.edit("b")
            await tabs.release()
        }
    }

    /// Review fix 3: re-opening a file whose tab is mid-close (a slow Save)
    /// ends with a tab for it that the pane tracks, never an untracked
    /// editor reported as opened.
    @Test
    func reopeningAFileWhileItsTabClosesLeavesATrackedTab() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let a = try sandbox.file("a.txt", "a")
            let writes = LeoGatedReads([], writes: [a])
            let (tabs, _) = makeTabs(answering: [.save], access: writes.makeAccess)
            try await tabs.open(file(a))
            let closingTab = try #require(tabs.selected)
            closingTab.document?.edit("a, saved")
            let closing = Task { await tabs.closeTab(closingTab) }
            await writes.waitUntil(.write, a)

            let reopening = Task { try await tabs.open(file(a), mode: .background) }
            // It queues behind the close on the tab's own queue.
            for _ in 0 ..< 3 { await Task.yield() }
            writes.release(.write, a)

            #expect(await closing.value)
            #expect(try await reopening.value == .opened)
            let tab = try #require(tabs.tab(for: file(a)), "a tab the pane tracks")
            #expect(tabs.tabs.count == 1)
            #expect(tab.document?.text == "a, saved")
            #expect(closingTab.document == nil)
            await tabs.release()
        }
    }

    @Test
    func tabDropsWhenGateClosesOrAbandonsItsEditor() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let (tabs, _) = makeTabs(answering: [.discard])
            for name in ["a", "b"] { try await tabs.open(file(try sandbox.file("\(name).txt", name))) }
            tabs.tabs[0].document?.edit("a, edited")

            tabs.tabs[0].abandon()
            #expect(names(tabs) == ["b.txt"])

            #expect(await tabs.tabs[0].close())
            #expect(tabs.tabs.isEmpty)
            #expect(tabs.selected == nil)
            #expect(!tabs.isOpen)
        }
    }

    @Test
    func nextPreviousWrap() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let (tabs, _) = makeTabs()
            for name in ["a", "b", "c"] { try await tabs.open(file(try sandbox.file("\(name).txt", name))) }

            tabs.selectNext()
            #expect(tabs.document?.displayName == "a.txt")
            tabs.selectPrevious()
            #expect(tabs.document?.displayName == "c.txt")
            tabs.selectPrevious()
            #expect(tabs.document?.displayName == "b.txt")
            await tabs.release()
        }
    }

    @Test
    func capEvictsOldestCleanTabNeverDirty() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let (tabs, prompts) = makeTabs()
            for index in 0..<LeoEditorTabs.tabLimit {
                try await tabs.open(file(try sandbox.file("f\(index).txt", "\(index)")))
            }
            tabs.tabs[0].document?.edit("edited")

            try await tabs.open(file(try sandbox.file("new.txt", "new")))

            #expect(tabs.tabs.count == LeoEditorTabs.tabLimit)
            #expect(names(tabs).contains("f0.txt"))
            #expect(!names(tabs).contains("f1.txt"))
            #expect(tabs.document?.displayName == "new.txt")
            #expect(prompts.asked.isEmpty)
            tabs.tabs[0].document?.edit("0")
            await tabs.release()
        }
    }
}
