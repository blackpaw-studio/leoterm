import Foundation

@testable import Ghostty

/// Reads (and, when asked, stats and writes) of the gated paths wait until
/// the test lets them through, so a test can finish operations in any
/// order it likes. One registry shared by every access it makes (each
/// document closes its own).
final class LeoGatedReads: @unchecked Sendable {
    enum Operation: Sendable {
        case read, stat, write
    }

    private struct Key: Hashable {
        let operation: Operation
        let path: String
    }

    private struct Gate {
        let reaching = AsyncStream<Void>.makeStream()
        let open = AsyncStream<Void>.makeStream()
    }

    private let gates: [Key: Gate]

    init(_ reads: [String], stats: [String] = [], writes: [String] = []) {
        let keys = reads.map { Key(operation: .read, path: $0) } + stats.map { Key(operation: .stat, path: $0) }
            + writes.map { Key(operation: .write, path: $0) }
        gates = Dictionary(uniqueKeysWithValues: keys.map { ($0, Gate()) })
    }

    /// A fresh local access whose gated operations wait.
    @MainActor func makeAccess(_ host: LeoHostID) -> any LeoFileAccess {
        Access(base: LeoFileAccessor.local(), gates: self)
    }

    func waitUntilReading(_ path: String) async { await waitUntil(.read, path) }

    func release(_ path: String) { release(.read, path) }

    func waitUntil(_ operation: Operation, _ path: String) async {
        guard let gate = gates[Key(operation: operation, path: path)] else { return }
        for await _ in gate.reaching.stream { return }
    }

    func release(_ operation: Operation, _ path: String) {
        gates[Key(operation: operation, path: path)]?.open.continuation.yield()
    }

    fileprivate func pass(_ operation: Operation, _ path: String) async {
        guard let gate = gates[Key(operation: operation, path: path)] else { return }
        gate.reaching.continuation.yield()
        for await _ in gate.open.stream { return }
    }

    private struct Access: LeoFileAccess {
        let base: any LeoFileAccess
        let gates: LeoGatedReads

        func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }

        func stat(_ path: String) async throws -> LeoFileStat {
            await gates.pass(.stat, path)
            return try await base.stat(path)
        }

        func homeDirectory() async throws -> String { try await base.homeDirectory() }

        func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents {
            await gates.pass(.read, path)
            return try await base.read(path, maxBytes: maxBytes)
        }

        func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
            await gates.pass(.write, path)
            return try await base.write(data, to: path, expecting: expected)
        }

        func close() async { await base.close() }
    }
}
