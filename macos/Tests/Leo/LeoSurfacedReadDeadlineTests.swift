import Foundation
import Testing

@testable import Ghostty

/// Security re-review #3: SFTP requests have no timeout of their own (the
/// transport fails them only when it closes), so a remote file swapped to
/// a FIFO after the stat would block OPEN/READ forever. A surfaced-file
/// open's first read is bounded: past the deadline the access is closed --
/// which fails the stuck request -- and the open fails, leaving the pane
/// free for the next open.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LeoSurfacedReadDeadlineTests {
    @Test func aReadThatNeverAnswersFailsAtTheDeadlineAndClosesTheAccess() async throws {
        let base = HangingAccess(hanging: ["/w/pipe"])
        let access = LeoReadDeadline(seconds: 5, sleep: { _ in }).wrap(base)
        await #expect(throws: LeoFileAccessError.self) {
            _ = try await access.read("/w/pipe", maxBytes: 1024)
        }
        try await until { await base.isClosed }
    }

    @Test func aReadThatAnswersInTimeIsUntouched() async throws {
        let base = HangingAccess(hanging: [])
        let access = LeoReadDeadline(seconds: 5, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }).wrap(base)
        let contents = try await access.read("/w/a.txt", maxBytes: 1024)
        #expect(contents.data == Data("hello".utf8))
        #expect(!(await base.isClosed))
    }

    @Test func thePaneIsNotWedgedByAHungSurfacedOpen() async throws {
        let pane = LeoEditorPaneModel(makeAccess: { _ in HangingAccess(hanging: ["/w/pipe"]) })
        let deadline = LeoReadDeadline(seconds: 5, sleep: { _ in })
        await #expect(throws: LeoFileAccessError.self) {
            try await pane.open(LeoEditorFileID(host: .remote("work"), path: "/w/pipe"), readDeadline: deadline)
        }
        let outcome = try await pane.open(LeoEditorFileID(host: .remote("work"), path: "/w/a.txt"))
        #expect(outcome == .opened)
        #expect(pane.document?.fileID.path == "/w/a.txt")
    }

    @Test func surfacedOpensUseTheDeadline() {
        #expect(LeoReadDeadline.surfacedOpen.seconds > 0)
    }
}

/// A file access whose reads of `hanging` paths never answer until it's
/// closed, like an SFTP OPEN on a FIFO; everything else reads "hello".
actor HangingAccess: LeoFileAccess {
    private let hanging: Set<String>
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private(set) var isClosed = false

    init(hanging: Set<String>) { self.hanging = hanging }

    func list(_ path: String) async throws -> [LeoFileEntry] { [] }
    func stat(_ path: String) async throws -> LeoFileStat { Self.stat }
    func homeDirectory() async throws -> String { "/w" }

    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents {
        guard !isClosed else { throw LeoFileAccessError.closed }
        if hanging.contains(path) {
            // A guard so a missing deadline fails the test instead of
            // hanging the run: not a LeoFileAccessError.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.failWaiters(HangGuard())
            }
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        return LeoFileContents(data: Data("hello".utf8), stat: Self.stat)
    }

    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat { Self.stat }

    func close() async {
        isClosed = true
        failWaiters(LeoFileAccessError.closed)
    }

    private func failWaiters(_ error: Error) {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(throwing: error) }
    }

    private static let stat = LeoFileStat(kind: .file, size: 5, modified: Date(timeIntervalSince1970: 0), permissions: 0o644)
}

private struct HangGuard: Error {}
