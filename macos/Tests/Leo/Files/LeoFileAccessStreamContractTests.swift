import Darwin
import Foundation
import Testing

@testable import Ghostty

/// The streaming read contract (B-279): `read(_:into:)` pushes a file into a
/// sink in bounded pieces, identically for local and remote, and refuses
/// anything but a regular file before a byte moves.
struct LeoFileAccessStreamContractTests {
    static let kinds: [LeoFileBackendKind] = [.local, .sftp, .sftpSmallChunks]

    @Test(arguments: kinds)
    func streamsAFileInBoundedChunks(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            // Spans several pushes for every backend's window.
            let payload = leoPatternData(count: max(200_000, 2 * kind.readWindowSize + 1))
            let path = sandbox.path("big.bin")
            try payload.write(to: URL(fileURLWithPath: path))
            let before = try await access.stat(path)
            let sink = LeoRecordingByteSink()

            let stat = try await access.read(path, into: sink)

            #expect(sink.data == payload)
            #expect(sink.pushes.allSatisfy { $0 <= kind.readWindowSize })
            #expect(sink.pushes.count > 1)
            #expect(stat == before)
        }
    }

    @Test(arguments: kinds)
    func streamsAnEmptyFileWithoutPushing(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let path = try sandbox.file("empty", "")
            let sink = LeoRecordingByteSink()

            let stat = try await access.read(path, into: sink)

            #expect(stat.size == 0)
            #expect(sink.data.isEmpty)
        }
    }

    @Test(arguments: kinds)
    func streamRefusesAFolderOrFIFOWithoutBlocking(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let folder = try sandbox.directory("folder")
            let fifo = sandbox.path("pipe")
            try #require(mkfifo(fifo, 0o644) == 0)
            let sink = LeoRecordingByteSink()

            await #expect(throws: LeoFileAccessError.isADirectory(path: folder)) {
                try await access.read(folder, into: sink)
            }
            await #expect(throws: LeoFileAccessError.failed(path: fifo, reason: "it isn’t a regular file")) {
                try await access.read(fifo, into: sink)
            }
            #expect(sink.pushes.isEmpty)
        }
    }
}

extension LeoFileBackendKind {
    /// The most a streaming read may push to its sink at once.
    var readWindowSize: Int {
        switch self {
        case .local: LeoLocalFileBackend.readChunkSize
        case .sftpSmallChunks: 1000 * 3
        case .sftp, .sftpWithoutPosixRename, .sshEndToEnd: LeoSFTPOptions().chunkSize * LeoSFTPOptions().maxRequestsInFlight
        }
    }
}

/// Collects what a streaming read pushes, recording each push's size and
/// that every push lands at the running offset.
final class LeoRecordingByteSink: LeoFileByteSink, @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()
    private var sizes: [Int] = []
    /// Runs before each push is kept (with the push's index); may throw.
    private let beforePush: @Sendable (Int) async throws -> Void

    init(beforePush: @escaping @Sendable (Int) async throws -> Void = { _ in }) {
        self.beforePush = beforePush
    }

    var data: Data { lock.withLock { collected } }
    var pushes: [Int] { lock.withLock { sizes } }

    func write(_ data: Data, at offset: UInt64) async throws {
        try await beforePush(lock.withLock { sizes.count })
        try lock.withLock {
            guard offset == UInt64(collected.count) else { throw LeoFileAccessError.protocolError("out of order push") }
            collected.append(data)
            sizes.append(data.count)
        }
    }
}
