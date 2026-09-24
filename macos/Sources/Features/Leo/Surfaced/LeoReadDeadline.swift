import Foundation

/// Bounds a surfaced-file open's first read (B-013). SFTP requests
/// have no timeout of their own -- the transport fails them only when the
/// session closes -- so OPEN/READ of a file swapped to a FIFO after its
/// stat would never answer, wedging the editor pane's queue. Past the
/// deadline the access is closed, which fails the stuck request, and the
/// read throws. Only the first read is bounded: the document keeps the
/// access for saves and reloads afterwards.
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

    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents {
        let isFirst = lock.withLock {
            defer { firstReadTaken = true }
            return !firstReadTaken
        }
        guard isFirst else { return try await base.read(path, maxBytes: maxBytes) }
        let base = base
        let deadline = deadline
        return try await withCheckedThrowingContinuation { continuation in
            let outcome = LeoFirstOutcome(continuation)
            let timer = Task {
                try await deadline.sleep(UInt64(max(0, deadline.seconds) * 1_000_000_000))
                let timeout = LeoFileAccessError.failed(path: path, reason: "it didn’t answer in time")
                if outcome.finish(.failure(timeout)) { await base.close() }
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
