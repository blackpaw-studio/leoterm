import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif

@testable import Ghostty

struct LeoFileDropTests {
    static let kinds: [LeoFileBackendKind] = [.local, .sftp]

    @Test(arguments: kinds)
    func uploadsFilesInFinderOrderAndUsesDestinationBasenames(_ kind: LeoFileBackendKind) async throws {
        let source = try LeoFileSandbox()
        defer { source.cleanUp() }
        let first = try source.file("one file.txt", "one")
        let second = try source.file("two.txt", "two")
        try await withLeoFileSandbox(kind) { destination, access in
            let result = await LeoFileDrop.upload(
                [URL(fileURLWithPath: first), URL(fileURLWithPath: second)],
                to: destination.root,
                access: access
            )
            let firstContents = try destination.contents("one file.txt")
            let secondContents = try destination.contents("two.txt")

            #expect(result.uploaded.map(\.path) == [destination.path("one file.txt"), destination.path("two.txt")])
            #expect(result.failures.isEmpty)
            #expect(firstContents == "one")
            #expect(secondContents == "two")
            #expect(try destination.permissions("one file.txt") == 0o600, "\(kind) publishes owner-only staged permissions")
            #expect(try destination.permissions("two.txt") == 0o600, "\(kind) publishes owner-only staged permissions")
            #expect(result.shellText == Ghostty.Shell.escape(destination.path("one file.txt")) + " " + destination.path("two.txt"))
        }
    }

    @Test(arguments: kinds)
    func rejectsFoldersAndContinuesAfterIndividualFailures(_ kind: LeoFileBackendKind) async throws {
        let source = try LeoFileSandbox()
        defer { source.cleanUp() }
        let folder = try source.directory("folder")
        let clash = try source.file("clash.txt", "new")
        let good = try source.file("good.txt", "good")
        try await withLeoFileSandbox(kind) { destination, access in
            try destination.file("clash.txt", "original")
            let result = await LeoFileDrop.upload(
                [URL(fileURLWithPath: folder), URL(fileURLWithPath: clash), URL(fileURLWithPath: good)],
                to: destination.root,
                access: access
            )
            let clashContents = try destination.contents("clash.txt")
            let goodContents = try destination.contents("good.txt")

            #expect(result.uploaded.map(\.path) == [destination.path("good.txt")])
            #expect(result.failures.map(\.name) == ["folder", "clash.txt"])
            #expect(clashContents == "original")
            #expect(goodContents == "good")
            #expect(try destination.names() == ["clash.txt", "good.txt"], "\(kind) cleans an owned stage after conflict")
            #expect(result.errorMessage.contains("clash.txt: A file with this name already exists."))
        }
    }

    @Test
    func aSourceReplacedByASymlinkBeforeOpenNeverUploadsTheSymlinkTarget() async throws {
        let source = try LeoFileSandbox()
        let destination = try LeoFileSandbox()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        let sourcePath = try source.file("report.txt", "safe")
        let secretPath = try source.file("secret.txt", "must not upload")
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let access = LeoFileAccessor.local()

        let result = await LeoFileDrop.upload(
            [sourceURL], to: destination.root, access: access,
            beforeSourceOpen: { url in
                let held = url.deletingLastPathComponent().appendingPathComponent("held.txt")
                try FileManager.default.moveItem(at: url, to: held)
                try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: secretPath)
            }
        )

        #expect(result.uploaded.isEmpty)
        #expect(result.failures.map(\.name) == ["report.txt"])
        #expect(try destination.names().isEmpty)
    }

    /// A NUL in any component would truncate the C path at `open`, so
    /// `…/secret%00/x/innocent.txt` must never read `secret`.
    @Test
    func aNULInAParentComponentNeverOpensATruncatedPath() async throws {
        let source = try LeoFileSandbox()
        let destination = try LeoFileSandbox()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        let secret = try source.file("secret", "must not upload")
        let url = try #require(URL(string: URL(fileURLWithPath: secret).absoluteString + "%00/x/innocent.txt"))
        #expect(url.path(percentEncoded: false).contains("\0"))

        let result = await LeoFileDrop.upload([url], to: destination.root, access: LeoFileAccessor.local())

        #expect(result.uploaded.isEmpty)
        #expect(result.failures == [LeoFileDrop.Failure(name: "innocent.txt", message: "This item doesn’t have a valid file name.")])
        #expect(try destination.names().isEmpty)
    }

    @Test
    func aFIFOIsRejectedWithoutOpeningItForABlockingRead() async throws {
        let source = try LeoFileSandbox()
        let destination = try LeoFileSandbox()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        let fifo = source.path("pipe")
        #expect(mkfifo(fifo, 0o600) == 0)

        let result = await LeoFileDrop.upload(
            [URL(fileURLWithPath: fifo)], to: destination.root, access: LeoFileAccessor.local()
        )

        #expect(result.uploaded.isEmpty)
        #expect(result.failures.map(\.name) == ["pipe"])
        #expect(try destination.names().isEmpty)
    }

    @Test
    func cancellationWhileReadingNeverCreatesTheDestination() async throws {
        let source = try LeoFileSandbox()
        defer { source.cleanUp() }
        let path = try source.file("large.txt", String(repeating: "x", count: 1024 * 1024))
        let gate = LeoFileDropReadGate()
        let access = LeoFileDropCreateRecorder()
        let upload = Task {
            await LeoFileDrop.upload(
                [URL(fileURLWithPath: path)], to: "/workspace", access: access,
                beforeSourceRead: { _ in await gate.enter() }
            )
        }
        await gate.waitUntilEntered()

        upload.cancel()
        await gate.release()
        _ = await upload.value

        #expect(await access.createdPaths.isEmpty)
    }
}

private actor LeoFileDropReadGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocker: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        await withCheckedContinuation { blocker = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        blocker?.resume()
        blocker = nil
    }
}

private actor LeoFileDropCreateRecorder: LeoFileAccess {
    private(set) var createdPaths: [String] = []

    func list(_ path: String) async throws -> [LeoFileEntry] { [] }
    func stat(_ path: String) async throws -> LeoFileStat { fatalError() }
    func homeDirectory() async throws -> String { "/" }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { fatalError() }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat { fatalError() }
    func create(at path: String, from source: any LeoFileByteSource) async throws -> LeoFileStat {
        createdPaths.append(path)
        return LeoFileStat(kind: .file, size: 0, modified: .now, permissions: 0o644)
    }
    func close() async {}
}
