import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// A preview's fetch generations (B-278): a fetch superseded by a newer
/// one never lands, whatever order they finish in, and its folder goes.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LeoFilePreviewTests {
    /// Fetch `n` waits until `release(n)`, ignoring cancellation (like a
    /// read already on the wire), then returns `/tmp/fetch-n/a.png`.
    private final class Fetches: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<Int> = []
        private var discardedFolders: [String] = []

        var discarded: [String] { lock.withLock { discardedFolders } }
        var startedCount: Int { lock.withLock { started } }

        func fetch() async -> LeoFilePreviewFetch {
            let index = lock.withLock {
                started += 1
                return started
            }
            await withCheckedContinuation { continuation in
                let isReleased = lock.withLock {
                    if released.contains(index) { return true }
                    waiting[index] = continuation
                    return false
                }
                if isReleased { continuation.resume() }
            }
            let folder = URL(fileURLWithPath: "/tmp/fetch-\(index)")
            let stat = LeoFileStat(kind: .file, size: UInt64(index), modified: Date(timeIntervalSince1970: 0), permissions: 0o644)
            return LeoFilePreviewFetch(folder: folder, file: folder.appendingPathComponent("a.png"), stat: stat)
        }

        func release(_ index: Int) {
            let continuation = lock.withLock {
                released.insert(index)
                return waiting.removeValue(forKey: index)
            }
            continuation?.resume()
        }

        func discard(_ fetch: LeoFilePreviewFetch) {
            lock.withLock { discardedFolders.append(fetch.folder.lastPathComponent) }
        }
    }

    @Test func anOlderFetchLandingLateIsThrownAway() async throws {
        let fetches = Fetches()
        let preview = LeoFilePreview(typeName: "PNG image", fetch: { _ in await fetches.fetch() }, discard: { fetches.discard($0) })
        var landed: [UInt64] = []

        preview.refresh(size: 1) { landed.append($0.size) }
        try await until { fetches.startedCount == 1 }
        preview.refresh(size: 2) { landed.append($0.size) }
        try await until { fetches.startedCount == 2 }
        fetches.release(2)
        await preview.settle()
        #expect(preview.state == .ready(URL(fileURLWithPath: "/tmp/fetch-2/a.png")))

        fetches.release(1)
        try await until { fetches.discarded == ["fetch-1"] }

        #expect(preview.state == .ready(URL(fileURLWithPath: "/tmp/fetch-2/a.png")))
        #expect(landed == [2])
        await preview.close()
        #expect(fetches.discarded == ["fetch-1", "fetch-2"])
        #expect(preview.state == .closed)
    }

    @Test func aRefetchReplacesTheShownFileAndDeletesTheOldOne() async throws {
        let fetches = Fetches()
        let preview = LeoFilePreview(typeName: "PNG image", fetch: { _ in await fetches.fetch() }, discard: { fetches.discard($0) })
        fetches.release(1)
        fetches.release(2)

        preview.refresh(size: 1) { _ in }
        await preview.settle()
        preview.refresh(size: 1) { _ in }
        #expect(preview.state == .ready(URL(fileURLWithPath: "/tmp/fetch-1/a.png")), "the old file stays until the new one lands")
        await preview.settle()

        #expect(preview.state == .ready(URL(fileURLWithPath: "/tmp/fetch-2/a.png")))
        #expect(fetches.discarded == ["fetch-1"])
        await preview.close()
    }
}
