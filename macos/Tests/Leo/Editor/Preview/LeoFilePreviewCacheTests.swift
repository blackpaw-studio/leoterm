import Foundation
import Testing

@testable import Ghostty

/// The preview cache (B-278): media and documents stream through
/// `LeoFileAccess` into a private folder of their own, which nothing but
/// its own discard (or a failed fetch) removes.
struct LeoFilePreviewCacheTests {
    static let kinds: [LeoFileBackendKind] = [.local, .sftp, .sftpSmallChunks]

    private func withCache(
        _ kind: LeoFileBackendKind,
        fetchLimit: UInt64 = LeoFilePreviewCache.fetchLimit,
        _ body: (LeoFileSandbox, any LeoFileAccess, LeoFilePreviewCache) async throws -> Void
    ) async throws {
        let temp = try LeoFileSandbox()
        defer { temp.cleanUp() }
        let cache = LeoFilePreviewCache(root: URL(fileURLWithPath: temp.path("previews")), fetchLimit: fetchLimit)
        try await withLeoFileSandbox(kind) { workspace, access in
            try await body(workspace, access, cache)
        }
    }

    private func entries(_ cache: LeoFilePreviewCache) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: cache.root.path)) ?? []
    }

    @Test(arguments: kinds)
    func fetchesIntoPrivateFolder(_ kind: LeoFileBackendKind) async throws {
        try await withCache(kind) { workspace, access, cache in
            let payload = leoPatternData(count: 2 * kind.readWindowSize + 7)
            let path = workspace.path("shot.png")
            try payload.write(to: URL(fileURLWithPath: path))
            let before = try await access.stat(path)

            let fetch = try await cache.fetch(path, access: access)

            #expect(fetch.file.lastPathComponent == "shot.png")
            #expect(fetch.file.deletingLastPathComponent() == fetch.folder)
            #expect(try Data(contentsOf: fetch.file) == payload)
            let mode = try FileManager.default.attributesOfItem(atPath: fetch.folder.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o700)
            #expect(fetch.stat.version == before.version)
            cache.discard(fetch)
        }
    }

    @Test(arguments: kinds)
    func cancelledFetchLeavesNothing(_ kind: LeoFileBackendKind) async throws {
        try await withCache(kind) { workspace, access, cache in
            let path = workspace.path("movie.mp4")
            try leoPatternData(count: 3 * kind.readWindowSize).write(to: URL(fileURLWithPath: path))
            let task = Task {
                try await cache.fetch(path, access: access) { _ in withUnsafeCurrentTask { $0?.cancel() } }
            }

            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(entries(cache).isEmpty)
        }
    }

    @Test func discardRemovesOnlyItsFolder() async throws {
        try await withCache(.local) { workspace, access, cache in
            let path = try workspace.file("a.pdf", "%PDF")
            let first = try await cache.fetch(path, access: access)
            let second = try await cache.fetch(path, access: access)
            let outside = try workspace.directory("not-ours")

            cache.discard(first)
            cache.discard(LeoFilePreviewFetch(folder: URL(fileURLWithPath: outside), file: URL(fileURLWithPath: outside + "/x"), stat: first.stat))

            #expect(!FileManager.default.fileExists(atPath: first.folder.path))
            #expect(FileManager.default.fileExists(atPath: second.file.path))
            #expect(FileManager.default.fileExists(atPath: outside))
            #expect(first.folder != second.folder)
        }
    }

    @Test(arguments: kinds)
    func refusesOverFetchLimit(_ kind: LeoFileBackendKind) async throws {
        try await withCache(kind, fetchLimit: 10) { workspace, access, cache in
            let path = try workspace.file("big.mov", String(repeating: "x", count: 20))
            let pushes = LeoCounter()

            await #expect(throws: LeoFileAccessError.tooLarge(path: path, size: 20, limit: 10)) {
                try await cache.fetch(path, access: access) { _ in pushes.increment() }
            }
            #expect(pushes.value == 0)
            #expect(entries(cache).isEmpty)
        }
    }

    @Test func anUnsafeNameIsStoredUnderAFixedOne() async throws {
        try await withCache(.local) { workspace, access, cache in
            let path = try workspace.file("a\nb.png", "x")
            let fetch = try await cache.fetch(path, access: access)
            #expect(fetch.file.lastPathComponent == "preview.png")
            cache.discard(fetch)
        }
    }
}

/// A thread-safe counter for `@Sendable` hooks.
final class LeoCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
