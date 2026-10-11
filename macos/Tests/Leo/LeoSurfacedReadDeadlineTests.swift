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

    /// B-278: previews stream (`read(_:into:)`); a stream that never sends
    /// its first chunk fails at the deadline and closes the access.
    @Test func streamWithoutFirstChunkTimesOut() async throws {
        let base = HangingAccess(hanging: ["/w/pipe"])
        let access = LeoReadDeadline(seconds: 5, sleep: { _ in }).wrap(base)
        await #expect(throws: LeoFileAccessError.failed(path: "/w/pipe", reason: "it didn’t answer in time")) {
            try await access.read("/w/pipe", into: LeoRecordingByteSink())
        }
        try await until { await base.isClosed }
    }

    /// Only the first chunk is bounded: a slow download that has started
    /// isn't cut off at the deadline.
    @Test func startedStreamIsNotCut() async throws {
        let (firstChunk, sentFirst) = AsyncStream<Void>.makeStream()
        let (slept, wake) = AsyncStream<Void>.makeStream()
        let base = TwoChunkAccess(afterFirst: { sentFirst.yield() }, beforeSecond: { for await _ in slept { break } })
        let deadline = LeoReadDeadline(seconds: 5, sleep: { _ in
            for await _ in firstChunk { break }
            wake.yield()
        })
        let sink = LeoRecordingByteSink()

        let stat = try await deadline.wrap(base).read("/w/a.mov", into: sink)

        #expect(stat.size == 2)
        #expect(sink.data == Data("ab".utf8))
        for _ in 0..<10 { await Task.yield() }
        #expect(!(await base.isClosed))
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

    func read(_ path: String, into sink: any LeoFileByteSink) async throws -> LeoFileStat {
        let contents = try await read(path, maxBytes: .max)
        try await sink.write(contents.data, at: 0)
        return contents.stat
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

/// Streams "a", runs `afterFirst`, waits on `beforeSecond`, then streams
/// "b" -- unless closed meanwhile.
private actor TwoChunkAccess: LeoFileAccess {
    private let afterFirst: @Sendable () -> Void
    private let beforeSecond: @Sendable () async -> Void
    private(set) var isClosed = false

    init(afterFirst: @escaping @Sendable () -> Void, beforeSecond: @escaping @Sendable () async -> Void) {
        self.afterFirst = afterFirst
        self.beforeSecond = beforeSecond
    }

    private static let stat = LeoFileStat(kind: .file, size: 2, modified: Date(timeIntervalSince1970: 0), permissions: 0o644)

    func list(_ path: String) async throws -> [LeoFileEntry] { [] }
    func stat(_ path: String) async throws -> LeoFileStat { Self.stat }
    func homeDirectory() async throws -> String { "/w" }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { throw LeoFileAccessError.closed }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat { Self.stat }
    func close() async { isClosed = true }

    func read(_ path: String, into sink: any LeoFileByteSink) async throws -> LeoFileStat {
        try await sink.write(Data("a".utf8), at: 0)
        afterFirst()
        await beforeSecond()
        guard !isClosed else { throw LeoFileAccessError.closed }
        try await sink.write(Data("b".utf8), at: 1)
        return Self.stat
    }
}
