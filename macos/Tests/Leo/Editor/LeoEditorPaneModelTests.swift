import Foundation
import Testing

@testable import Ghostty

/// One editor pane per window: opening another file replaces the
/// document, asking first (Save / Don't Save / Cancel) when it has unsaved
/// edits; the recents list lets you switch back.
@MainActor
struct LeoEditorPaneModelTests {
    nonisolated static let kinds: [LeoFileBackendKind] = [.local, .sftp]

    private final class Prompts {
        var asked: [String] = []
        var answer: LeoUnsavedChangesChoice
        init(_ answer: LeoUnsavedChangesChoice) { self.answer = answer }
    }

    private func makePane(_ kind: LeoFileBackendKind, answering answer: LeoUnsavedChangesChoice = .cancel) -> (LeoEditorPaneModel, Prompts) {
        let prompts = Prompts(answer)
        let pane = LeoEditorPaneModel(makeAccess: { _ in kind.makeAccess() })
        pane.confirmUnsaved = { document in
            prompts.asked.append(document.displayName)
            return prompts.answer
        }
        return (pane, prompts)
    }

    private func file(_ path: String) -> LeoEditorFileID { LeoEditorFileID(host: .local, path: path) }

    @Test(arguments: kinds)
    func opensIntoAnEmptyPaneWithoutAsking(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let (pane, prompts) = makePane(kind)
            let path = try sandbox.file("a.txt", "a")

            #expect(try await pane.open(file(path)) == .opened)

            #expect(pane.document?.text == "a")
            #expect(prompts.asked.isEmpty)
            await pane.close()
        }
    }

    @Test(arguments: kinds)
    func aCleanDocumentIsReplacedWithoutAsking(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let (pane, prompts) = makePane(kind)
            try await pane.open(file(try sandbox.file("a.txt", "a")))

            #expect(try await pane.open(file(try sandbox.file("b.txt", "b"))) == .opened)

            #expect(pane.document?.text == "b")
            #expect(prompts.asked.isEmpty)
            await pane.close()
        }
    }

    @Test(arguments: kinds)
    func cancelKeepsTheDirtyDocument(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let (pane, prompts) = makePane(kind, answering: .cancel)
            try await pane.open(file(try sandbox.file("a.txt", "a")))
            pane.document?.edit("a, edited")

            #expect(try await pane.open(file(try sandbox.file("b.txt", "b"))) == .cancelled)

            #expect(prompts.asked == ["a.txt"])
            #expect(pane.document?.displayName == "a.txt")
            #expect(pane.document?.text == "a, edited")
            #expect(pane.document?.isDirty == true)
            pane.confirmUnsaved = { _ in .discard }
            await pane.close()
        }
    }

    @Test(arguments: kinds)
    func dontSaveDiscardsAndReplaces(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let (pane, _) = makePane(kind, answering: .discard)
            try await pane.open(file(try sandbox.file("a.txt", "a")))
            pane.document?.edit("a, edited")

            #expect(try await pane.open(file(try sandbox.file("b.txt", "b"))) == .opened)

            #expect(pane.document?.displayName == "b.txt")
            #expect(try sandbox.contents("a.txt") == "a")
            await pane.close()
        }
    }

    @Test(arguments: kinds)
    func saveWritesThenReplaces(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let (pane, _) = makePane(kind, answering: .save)
            try await pane.open(file(try sandbox.file("a.txt", "a")))
            pane.document?.edit("a, edited")

            #expect(try await pane.open(file(try sandbox.file("b.txt", "b"))) == .opened)

            #expect(pane.document?.displayName == "b.txt")
            #expect(try sandbox.contents("a.txt") == "a, edited")
            await pane.close()
        }
    }

    @Test(arguments: kinds)
    func aSaveThatConflictsKeepsTheCurrentDocument(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let (pane, _) = makePane(kind, answering: .save)
            try await pane.open(file(try sandbox.file("a.txt", "a")))
            pane.document?.edit("mine")
            try sandbox.file("a.txt", "theirs, longer")

            #expect(try await pane.open(file(try sandbox.file("b.txt", "b"))) == .cancelled)

            #expect(pane.document?.displayName == "a.txt")
            #expect(pane.document?.diskState == .changed)
            #expect(try sandbox.contents("a.txt") == "theirs, longer")
            pane.confirmUnsaved = { _ in .discard }
            await pane.close()
        }
    }

    @Test(arguments: kinds)
    func aFileThatCantOpenNeverPromptsAndKeepsTheCurrentDocument(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let (pane, prompts) = makePane(kind, answering: .discard)
            try await pane.open(file(try sandbox.file("a.txt", "a")))
            pane.document?.edit("a, edited")
            let missing = sandbox.path("missing.txt")

            await #expect(throws: LeoFileAccessError.notFound(path: missing)) { try await pane.open(file(missing)) }

            #expect(prompts.asked.isEmpty)
            #expect(pane.document?.text == "a, edited")
            await pane.close()
        }
    }

    @Test(arguments: kinds)
    func reopeningTheOpenFileKeepsEditsAndRevealsTheLine(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let (pane, prompts) = makePane(kind)
            let path = try sandbox.file("a.txt", "1\n2\n3\n")
            try await pane.open(file(path))
            pane.document?.edit("1\n2\n3\n4\n")
            let document = pane.document

            #expect(try await pane.open(file(path), line: 3, column: 2) == .alreadyOpen)

            #expect(prompts.asked.isEmpty)
            #expect(pane.document === document)
            #expect(pane.document?.text == "1\n2\n3\n4\n")
            #expect(pane.reveal?.line == 3)
            #expect(pane.reveal?.column == 2)
            pane.confirmUnsaved = { _ in .discard }
            await pane.close()
        }
    }

    @Test func eachRevealIsDistinctEvenForTheSameLine() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let (pane, _) = makePane(.local)
            let path = try sandbox.file("a.txt", "1\n2\n")
            try await pane.open(file(path), line: 2)
            let first = pane.reveal

            try await pane.open(file(path), line: 2)

            #expect(pane.reveal?.line == 2)
            #expect(pane.reveal != first)
            await pane.close()
        }
    }

    @Test func recentsAreMostRecentFirstDedupedAndCapped() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let (pane, _) = makePane(.local)
            let paths = try (0..<12).map { try sandbox.file("f\($0).txt", "\($0)") }
            for path in paths { try await pane.open(file(path)) }
            try await pane.open(file(paths[5]))

            #expect(pane.recents.count == LeoEditorPaneModel.recentsLimit)
            #expect(pane.recents.first == file(paths[5]))
            #expect(pane.recents.dropFirst().first == file(paths[11]))
            #expect(pane.recents.filter { $0 == file(paths[5]) }.count == 1)
            #expect(!pane.recents.contains(file(paths[0])))
            await pane.close()
        }
    }

    @Test(arguments: kinds)
    func closingADirtyDocumentAsksFirst(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let (pane, prompts) = makePane(kind, answering: .cancel)
            try await pane.open(file(try sandbox.file("a.txt", "a")))
            pane.document?.edit("edited")

            #expect(await pane.close() == false)
            #expect(pane.document != nil)

            prompts.answer = .discard
            #expect(await pane.close() == true)
            #expect(pane.document == nil)
            #expect(prompts.asked == ["a.txt", "a.txt"])
            #expect(try sandbox.contents("a.txt") == "a")
        }
    }

    @Test func closingAnEmptyPaneSucceeds() async {
        let (pane, prompts) = makePane(.local)
        #expect(await pane.close() == true)
        #expect(prompts.asked.isEmpty)
    }
}
