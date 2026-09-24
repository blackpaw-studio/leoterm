import Foundation
import Testing

@testable import Ghostty

/// B-013 review #1: a surfaced file's identity check happens where the
/// pane commits the new document -- after the read and after the
/// unsaved-changes prompt -- so an agent restart (or host switch) during
/// either never lands the old incarnation's file in the pane.
@MainActor
struct LeoSurfacedPaneCommitTests {
    nonisolated static let kinds: [LeoFileBackendKind] = [.local, .sftp]

    private func file(_ path: String) -> LeoEditorFileID { LeoEditorFileID(host: .local, path: path) }

    @Test(arguments: kinds)
    func anOpenNoLongerWantedAfterItsReadLeavesThePaneAlone(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let pane = LeoEditorPaneModel(makeAccess: { _ in kind.makeAccess() })
            try await pane.open(file(try sandbox.file("a.txt", "a")))
            // The agent restarted while the open waited in the queue or read.
            let outcome = try await pane.open(file(try sandbox.file("b.txt", "b")), isStillWanted: { false })
            #expect(outcome == .cancelled)
            #expect(pane.document?.displayName == "a.txt")
            await pane.close()
        }
    }

    @Test(arguments: kinds)
    func anOpenNoLongerWantedOnceTheUnsavedPromptResolvesLeavesThePaneAlone(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let pane = LeoEditorPaneModel(makeAccess: { _ in kind.makeAccess() })
            try await pane.open(file(try sandbox.file("a.txt", "a")))
            pane.document?.edit("a, edited")
            var wanted = true
            pane.confirmUnsaved = { _ in
                wanted = false // the agent restarted while the sheet was up
                return .discard
            }
            let outcome = try await pane.open(file(try sandbox.file("b.txt", "b")), isStillWanted: { wanted })
            #expect(outcome == .cancelled)
            #expect(pane.document?.displayName == "a.txt")
            #expect(pane.document?.text == "a, edited", "nothing discarded for an open that didn't happen")
            pane.confirmUnsaved = { _ in .discard }
            await pane.close()
        }
    }

    @Test(arguments: kinds)
    func anAlreadyOpenFileNoLongerWantedIsNotRevealed(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            let pane = LeoEditorPaneModel(makeAccess: { _ in kind.makeAccess() })
            let path = try sandbox.file("a.txt", "a")
            try await pane.open(file(path))
            #expect(try await pane.open(file(path), line: 1, isStillWanted: { false }) == .cancelled)
            await pane.close()
        }
    }
}
