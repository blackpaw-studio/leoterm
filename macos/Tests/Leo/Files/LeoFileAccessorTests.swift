import Foundation
import Testing

@testable import Ghostty

/// `LeoFileAccessor` semantics that need a backend misbehaving on cue.
struct LeoFileAccessorTests {
    /// Once the rename has happened the save is done: a failure to stat the
    /// file afterwards (say the connection drops) must not turn it into a
    /// reported failure the editor would retry into a false conflict.
    @Test func aSaveThatRenamedSucceedsEvenIfTheFollowUpStatFails() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let path = try sandbox.file("f.txt", "old")
        let backend = LeoStatFailsAfterReplaceBackend()
        let access = LeoFileAccessor(backend: backend)
        let version = try await access.read(path, maxBytes: 100).stat.version

        let written = try await access.write(Data("new!".utf8), to: path, expecting: version)

        #expect(try sandbox.contents("f.txt") == "new!")
        #expect(written.size == 4)
        #expect(written.version == (try await LeoFileAccessor.local().stat(path)).version)
    }
}

/// The local backend, except every `stat` after the first `replace` fails
/// as if the connection had dropped.
private final class LeoStatFailsAfterReplaceBackend: LeoFileAccessBackend, @unchecked Sendable {
    private let base = LeoLocalFileBackend()
    private let lock = NSLock()
    private var replaced = false

    func stat(_ path: String) async throws -> LeoFileStat {
        if lock.withLock({ replaced }) { throw LeoFileAccessError.disconnected }
        return try await base.stat(path)
    }

    func lstat(_ path: String) async throws -> LeoFileStat { try await base.lstat(path) }
    func realpath(_ path: String) async throws -> String { try await base.realpath(path) }
    func entries(of directory: String) async throws -> [LeoFileEntry] { try await base.entries(of: directory) }
    func contents(of path: String, limit: UInt64) async throws -> Data { try await base.contents(of: path, limit: limit) }
    func create(_ path: String, data: Data, permissions: UInt16?) async throws {
        try await base.create(path, data: data, permissions: permissions)
    }
    func remove(_ path: String) async throws { try await base.remove(path) }

    func replace(_ destination: String, with source: String) async throws {
        try await base.replace(destination, with: source)
        lock.withLock { replaced = true }
    }
}
