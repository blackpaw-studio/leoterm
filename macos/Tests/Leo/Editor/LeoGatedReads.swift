import Foundation

@testable import Ghostty

/// Reads of the gated paths wait until the test lets them through, so a
/// test can finish opens in any order it likes. One registry shared by
/// every access it makes (each document closes its own).
final class LeoGatedReads: @unchecked Sendable {
    private struct Gate {
        let reading = AsyncStream<Void>.makeStream()
        let open = AsyncStream<Void>.makeStream()
    }

    private let gates: [String: Gate]

    init(_ paths: [String]) {
        gates = Dictionary(uniqueKeysWithValues: paths.map { ($0, Gate()) })
    }

    /// A fresh local access whose reads of the gated paths wait.
    @MainActor func makeAccess(_ host: LeoHostID) -> any LeoFileAccess {
        Access(base: LeoFileAccessor.local(), reads: self)
    }

    func waitUntilReading(_ path: String) async {
        guard let gate = gates[path] else { return }
        for await _ in gate.reading.stream { return }
    }

    func release(_ path: String) {
        gates[path]?.open.continuation.yield()
    }

    fileprivate func pass(_ path: String) async {
        guard let gate = gates[path] else { return }
        gate.reading.continuation.yield()
        for await _ in gate.open.stream { return }
    }

    private struct Access: LeoFileAccess {
        let base: any LeoFileAccess
        let reads: LeoGatedReads

        func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
        func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
        func homeDirectory() async throws -> String { try await base.homeDirectory() }

        func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents {
            await reads.pass(path)
            return try await base.read(path, maxBytes: maxBytes)
        }

        func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
            try await base.write(data, to: path, expecting: expected)
        }

        func close() async { await base.close() }
    }
}
