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

    @Test func aFailedExclusiveCreateNeverLeavesAPartialDestination() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let path = sandbox.path("upload.txt")
        let access = LeoFileAccessor(backend: LeoPartialCreateThenDisconnectBackend())

        await #expect(throws: (any Error).self) {
            try await access.create(Data("complete contents".utf8), at: path)
        }

        #expect(!FileManager.default.fileExists(atPath: path))
        let names = try sandbox.names()
        #expect(names.count == 1, "a disconnect may retain one uncertain private stage")
        #expect(names[0].hasPrefix(".upload.txt.leo-") && names[0].hasSuffix(".tmp"))
        #expect(try sandbox.contents(names[0]) == "comp")
        #expect(try await LeoFileAccessor.local().stat(sandbox.path(names[0])).permissions == 0o600)
    }

    @Test func anOrdinaryWriteFailureCleansItsOwnedPrivateStage() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let path = sandbox.path("upload.txt")
        let access = LeoFileAccessor(backend: LeoOrdinaryPartialFailureBackend())

        await #expect(throws: (any Error).self) {
            try await access.create(Data("complete contents".utf8), at: path)
        }

        #expect(try sandbox.names().isEmpty)
    }

    @Test func aPublicationFailureNeverRemovesAReplacementThatWonTheRace() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let path = sandbox.path("upload.txt")
        let backend = LeoReplacementWinsPublishRaceBackend()
        let access = LeoFileAccessor(backend: backend)

        await #expect(throws: LeoFileAccessError.conflict(path: path)) {
            try await access.create(Data("mine".utf8), at: path)
        }

        #expect(try sandbox.contents("upload.txt") == "rival")
        #expect(backend.removedPaths.count == 1)
        #expect(!backend.removedPaths.contains(path), "failure handling must never unlink the user destination")
        #expect(try sandbox.names() == ["upload.txt"])
    }

    @Test func aLostPublicationReplyIsIndeterminateAndIsNeverRetried() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let path = sandbox.path("upload.txt")
        let backend = LeoRenameCompletesThenDisconnectsBackend()
        let access = LeoFileAccessor(backend: backend)

        await #expect(throws: LeoFileAccessError.indeterminate(path: path)) {
            try await access.create(Data("mine".utf8), at: path)
        }

        #expect(backend.publishCount == 1)
        #expect(try sandbox.contents("upload.txt") == "mine")
        #expect(try sandbox.names() == ["upload.txt"])
    }
}

private struct LeoOrdinaryPartialFailureBackend: LeoFileAccessBackend {
    private let base = LeoLocalFileBackend()

    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func lstat(_ path: String) async throws -> LeoFileStat { try await base.lstat(path) }
    func realpath(_ path: String) async throws -> String { try await base.realpath(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func entries(of directory: String) async throws -> [LeoFileEntry] { try await base.entries(of: directory) }
    func contents(of path: String, limit: UInt64) async throws -> Data { try await base.contents(of: path, limit: limit) }
    func create(_ path: String, data: Data, permissions: UInt16?) async throws {
        try await base.create(path, data: Data(data.prefix(4)), permissions: permissions)
        try await base.remove(path)
        throw LeoFileAccessError.failed(path: path, reason: "simulated write failure")
    }
    func remove(_ path: String) async throws { try await base.remove(path) }
    func replace(_ destination: String, with source: String) async throws {
        try await base.replace(destination, with: source)
    }
}

/// Simulates the observable SFTP failure mode: the server accepted an OPEN
/// and one WRITE, then the ControlMaster disappeared before the file closed.
private struct LeoPartialCreateThenDisconnectBackend: LeoFileAccessBackend {
    private let base = LeoLocalFileBackend()

    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func lstat(_ path: String) async throws -> LeoFileStat { try await base.lstat(path) }
    func realpath(_ path: String) async throws -> String { try await base.realpath(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func entries(of directory: String) async throws -> [LeoFileEntry] { try await base.entries(of: directory) }
    func contents(of path: String, limit: UInt64) async throws -> Data { try await base.contents(of: path, limit: limit) }
    func create(_ path: String, data: Data, permissions: UInt16?) async throws {
        try await base.create(path, data: Data(data.prefix(4)), permissions: permissions)
        throw LeoFileAccessError.disconnected
    }
    func remove(_ path: String) async throws { try await base.remove(path) }
    func replace(_ destination: String, with source: String) async throws {
        try await base.replace(destination, with: source)
    }
}

private final class LeoReplacementWinsPublishRaceBackend: LeoFileAccessBackend, @unchecked Sendable {
    private let base = LeoLocalFileBackend()
    private let lock = NSLock()
    private var removed: [String] = []
    var removedPaths: [String] { lock.withLock { removed } }

    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func lstat(_ path: String) async throws -> LeoFileStat { try await base.lstat(path) }
    func realpath(_ path: String) async throws -> String { try await base.realpath(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func entries(of directory: String) async throws -> [LeoFileEntry] { try await base.entries(of: directory) }
    func contents(of path: String, limit: UInt64) async throws -> Data { try await base.contents(of: path, limit: limit) }
    func create(_ path: String, data: Data, permissions: UInt16?) async throws {
        try await base.create(path, data: data, permissions: permissions)
    }
    func publishExclusive(_ destination: String, with source: String) async throws {
        try await base.create(destination, data: Data("rival".utf8), permissions: nil)
        throw LeoFileAccessError.failed(path: destination, reason: "destination exists")
    }
    func remove(_ path: String) async throws {
        lock.withLock { removed.append(path) }
        try await base.remove(path)
    }
    func replace(_ destination: String, with source: String) async throws {
        try await base.replace(destination, with: source)
    }
}

private final class LeoRenameCompletesThenDisconnectsBackend: LeoFileAccessBackend, @unchecked Sendable {
    private let base = LeoLocalFileBackend()
    private let lock = NSLock()
    private var publishes = 0
    var publishCount: Int { lock.withLock { publishes } }

    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func lstat(_ path: String) async throws -> LeoFileStat { try await base.lstat(path) }
    func realpath(_ path: String) async throws -> String { try await base.realpath(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func entries(of directory: String) async throws -> [LeoFileEntry] { try await base.entries(of: directory) }
    func contents(of path: String, limit: UInt64) async throws -> Data { try await base.contents(of: path, limit: limit) }
    func create(_ path: String, data: Data, permissions: UInt16?) async throws {
        try await base.create(path, data: data, permissions: permissions)
    }
    func publishExclusive(_ destination: String, with source: String) async throws {
        lock.withLock { publishes += 1 }
        try await base.publishExclusive(destination, with: source)
        throw LeoFileAccessError.disconnected
    }
    func remove(_ path: String) async throws { try await base.remove(path) }
    func replace(_ destination: String, with source: String) async throws {
        try await base.replace(destination, with: source)
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
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
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
