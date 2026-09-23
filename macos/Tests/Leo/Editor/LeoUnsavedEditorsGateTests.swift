import Foundation
import Testing

@testable import Ghostty

/// Every close of a tab, a window or the app goes through the gate, so
/// unsaved editor edits are never dropped: a close that can ask asks about
/// each editor with unsaved edits in turn (Save / Don't Save / Cancel) and
/// is retried once all are resolved; Cancel drops it.
@MainActor
struct LeoUnsavedEditorsGateTests {
    /// Answers every prompt with `answer`, recording who was asked and
    /// which windows were brought forward.
    private final class Log {
        var asked: [String] = []
        var broughtForward: [String] = []
        var retries = 0
    }

    private func pane(answering answer: LeoUnsavedChangesChoice, log: Log) -> LeoEditorPaneModel {
        let pane = LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
        pane.confirmUnsaved = { document in
            log.asked.append(document.displayName)
            return answer
        }
        return pane
    }

    private func open(_ pane: LeoEditorPaneModel, _ path: String, editing: Bool) async throws {
        try await pane.open(LeoEditorFileID(host: .local, path: path))
        if editing, let document = pane.document { document.edit(document.text + "!") }
    }

    private func entry(_ pane: LeoEditorPaneModel, _ name: String, _ log: Log) -> LeoUnsavedEditorsGate.Entry {
        LeoUnsavedEditorsGate.Entry(editor: pane) { log.broughtForward.append(name) }
    }

    @Test func withoutUnsavedEditsTheCloseGoesAheadUnasked() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let clean = pane(answering: .cancel, log: log)
            try await open(clean, try sandbox.file("a.txt", "a"), editing: false)
            let empty = pane(answering: .cancel, log: log)
            let gate = LeoUnsavedEditorsGate()

            let tookOver = gate.deferClose(of: [entry(clean, "1", log), entry(empty, "2", log)]) { log.retries += 1 }

            #expect(!tookOver)
            #expect(log.asked.isEmpty)
            #expect(log.retries == 0)
            await clean.close()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func unsavedEditsAreAskedAboutFirstThenTheCloseIsRetried() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let dirty = pane(answering: .discard, log: log)
            try await open(dirty, try sandbox.file("a.txt", "a"), editing: true)
            let gate = LeoUnsavedEditorsGate()

            let (retries, retried) = AsyncStream<Void>.makeStream()

            try #require(gate.deferClose(of: [entry(dirty, "1", log)]) {
                log.retries += 1
                retried.yield()
            })
            for await _ in retries { break }

            #expect(log.asked == ["a.txt"])
            #expect(log.broughtForward == ["1"])
            #expect(log.retries == 1)
            #expect(dirty.document == nil)
            #expect(try sandbox.contents("a.txt") == "a")
            #expect(!gate.isAsking)
        }
    }

    @Test func eachEditorIsAskedInTurnAndCancelStopsTheClose() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let saved = pane(answering: .save, log: log)
            try await open(saved, try sandbox.file("a.txt", "a"), editing: true)
            let clean = pane(answering: .cancel, log: log)
            try await open(clean, try sandbox.file("b.txt", "b"), editing: false)
            let cancelled = pane(answering: .cancel, log: log)
            try await open(cancelled, try sandbox.file("c.txt", "c"), editing: true)
            let untouched = pane(answering: .discard, log: log)
            try await open(untouched, try sandbox.file("d.txt", "d"), editing: true)
            let gate = LeoUnsavedEditorsGate()

            let resolved = await gate.resolve([saved, clean, cancelled, untouched].enumerated().map { entry($1, "\($0)", log) })

            #expect(!resolved)
            #expect(log.asked == ["a.txt", "c.txt"])
            #expect(log.broughtForward == ["0", "2"])
            #expect(try sandbox.contents("a.txt") == "a!")
            #expect(saved.document == nil)
            #expect(cancelled.document?.isDirty == true)
            #expect(untouched.document?.isDirty == true)
            for pane in [clean, cancelled, untouched] {
                pane.confirmUnsaved = { _ in .discard }
                await pane.close()
            }
        }
    }

    /// Save fails while the file changed on disk (a banner is up): the
    /// edits stay, and so does everything else.
    @Test func aSaveThatCantGoThroughStopsTheClose() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let dirty = pane(answering: .save, log: log)
            try await open(dirty, try sandbox.file("a.txt", "a"), editing: true)
            try sandbox.file("a.txt", "a, changed elsewhere")
            #expect(await dirty.document?.checkDisk() == .conflict)
            let gate = LeoUnsavedEditorsGate()

            #expect(await !gate.resolve([entry(dirty, "1", log)]))

            #expect(dirty.document?.isDirty == true)
            #expect(try sandbox.contents("a.txt") == "a, changed elsewhere")
            dirty.confirmUnsaved = { _ in .discard }
            await dirty.close()
        }
    }

    /// One prompt at a time: a close asked for while the user is answering
    /// one (⌘W twice, ⌘Q during Close Tab) is dropped, not queued.
    @Test(.timeLimit(.minutes(1)))
    func aCloseRequestedWhileAskingIsDropped() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let (answers, answer) = AsyncStream<LeoUnsavedChangesChoice>.makeStream()
            let (prompts, prompted) = AsyncStream<Void>.makeStream()
            let dirty = LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
            dirty.confirmUnsaved = { document in
                log.asked.append(document.displayName)
                prompted.yield()
                for await choice in answers { return choice }
                return .cancel
            }
            try await open(dirty, try sandbox.file("a.txt", "a"), editing: true)
            let gate = LeoUnsavedEditorsGate()
            let (retries, retried) = AsyncStream<Void>.makeStream()

            try #require(gate.deferClose(of: [entry(dirty, "1", log)]) { retried.yield() })
            for await _ in prompts { break }
            #expect(gate.isAsking)
            #expect(gate.deferClose(of: [entry(dirty, "1", log)]) { log.retries += 1 })
            answer.yield(.discard)
            for await _ in retries { break }

            #expect(log.asked == ["a.txt"])
            #expect(log.retries == 0)
            #expect(!gate.isAsking)
        }
    }

    /// ...but closing a window with nothing unsaved goes ahead meanwhile.
    @Test(.timeLimit(.minutes(1)))
    func aCloseWithNothingUnsavedGoesAheadWhileAsking() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let (answers, answer) = AsyncStream<LeoUnsavedChangesChoice>.makeStream()
            let (prompts, prompted) = AsyncStream<Void>.makeStream()
            let dirty = LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
            dirty.confirmUnsaved = { _ in
                prompted.yield()
                for await choice in answers { return choice }
                return .cancel
            }
            try await open(dirty, try sandbox.file("a.txt", "a"), editing: true)
            let clean = pane(answering: .cancel, log: log)
            let gate = LeoUnsavedEditorsGate()
            let (retries, retried) = AsyncStream<Void>.makeStream()
            try #require(gate.deferClose(of: [entry(dirty, "1", log)]) { retried.yield() })
            for await _ in prompts { break }

            #expect(!gate.deferClose(of: [entry(clean, "2", log)]) { log.retries += 1 })

            answer.yield(.discard)
            for await _ in retries { break }
            #expect(log.retries == 0)
        }
    }
}
