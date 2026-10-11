import Foundation

/// Bounds a surfaced-file open's first read (B-013). SFTP requests
/// have no timeout of their own -- the transport fails them only when the
/// session closes -- so OPEN/READ of a file swapped to a FIFO after its
/// stat would never answer, wedging the editor pane's queue. Past the
/// deadline the access is closed, which fails the stuck request, and the
/// read throws. Only the first read is bounded: the document keeps the
/// access for saves and reloads afterwards. A first read that streams (a
/// preview's fetch, B-278) is bounded until its first chunk: a download
/// under way is never cut off however long it takes.
struct LeoReadDeadline: Sendable {
    /// The daemon client's default request timeout.
    static let surfacedOpen = LeoReadDeadline(seconds: 5)

    let seconds: TimeInterval
    var sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }

    func wrap(_ access: any LeoFileAccess) -> any LeoFileAccess {
        LeoDeadlineFileAccess(base: access, deadline: self)
    }
}

private final class LeoDeadlineFileAccess: LeoFileAccess, @unchecked Sendable {
    private let base: any LeoFileAccess
    private let deadline: LeoReadDeadline
    private let lock = NSLock()
    private var firstReadTaken = false

    init(base: any LeoFileAccess, deadline: LeoReadDeadline) {
        self.base = base
        self.deadline = deadline
    }

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func close() async { await base.close() }

    @discardableResult
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }

    private func takeFirstRead() -> Bool {
        lock.withLock {
            defer { firstReadTaken = true }
            return !firstReadTaken
        }
    }

    private static func timeout(_ path: String) -> LeoFileAccessError {
        .failed(path: path, reason: "it didn’t answer in time")
    }

    func read(_ path: String, into sink: any LeoFileByteSink) async throws -> LeoFileStat {
        guard takeFirstRead() else { return try await base.read(path, into: sink) }
        let base = base
        let deadline = deadline
        let watch = LeoFirstChunkWatch()
        let timer = Task {
            try await deadline.sleep(UInt64(max(0, deadline.seconds) * 1_000_000_000))
            if watch.expire() { await base.close() }
        }
        defer { timer.cancel() }
        do {
            let stat = try await base.read(path, into: WatchedSink(base: sink, watch: watch, timeout: Self.timeout(path)))
            guard watch.start() else { throw Self.timeout(path) }
            return stat
        } catch {
            if watch.hasExpired { throw Self.timeout(path) }
            throw error
        }
    }

    /// Marks the stream started on its first chunk; a chunk arriving after
    /// the deadline fails instead.
    private struct WatchedSink: LeoFileByteSink {
        let base: any LeoFileByteSink
        let watch: LeoFirstChunkWatch
        let timeout: LeoFileAccessError

        func write(_ data: Data, at offset: UInt64) async throws {
            guard watch.start() else { throw timeout }
            try await base.write(data, at: offset)
        }
    }

    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents {
        guard takeFirstRead() else { return try await base.read(path, maxBytes: maxBytes) }
        let base = base
        let deadline = deadline
        return try await withCheckedThrowingContinuation { continuation in
            let outcome = LeoFirstOutcome(continuation)
            let timer = Task {
                try await deadline.sleep(UInt64(max(0, deadline.seconds) * 1_000_000_000))
                if outcome.finish(.failure(Self.timeout(path))) { await base.close() }
            }
            Task {
                do {
                    let contents = try await base.read(path, maxBytes: maxBytes)
                    if outcome.finish(.success(contents)) { timer.cancel() }
                } catch {
                    if outcome.finish(.failure(error)) { timer.cancel() }
                }
            }
        }
    }
}

/// A streaming read's race with its deadline: the first chunk (or the end
/// of an empty file) and the deadline each try to settle it, and only the
/// first one does.
private final class LeoFirstChunkWatch: @unchecked Sendable {
    private enum Phase {
        case waiting, started, expired
    }

    private let lock = NSLock()
    private var phase = Phase.waiting

    var hasExpired: Bool { lock.withLock { phase == .expired } }

    /// `false` once the deadline has passed.
    func start() -> Bool {
        lock.withLock {
            if phase == .waiting { phase = .started }
            return phase == .started
        }
    }

    /// `true` when the deadline won: nothing had arrived.
    func expire() -> Bool {
        lock.withLock {
            guard phase == .waiting else { return false }
            phase = .expired
            return true
        }
    }
}

/// Resumes a continuation with whichever result comes first.
private final class LeoFirstOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LeoFileContents, Error>?

    init(_ continuation: CheckedContinuation<LeoFileContents, Error>) { self.continuation = continuation }

    /// `false` when another result already won.
    func finish(_ result: Result<LeoFileContents, Error>) -> Bool {
        guard let continuation = lock.withLock({ () -> CheckedContinuation<LeoFileContents, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }) else { return false }
        continuation.resume(with: result)
        return true
    }
}
