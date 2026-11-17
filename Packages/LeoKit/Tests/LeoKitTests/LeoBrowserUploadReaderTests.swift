import Foundation
import Testing

@testable import LeoKit

/// The browser upload reader over the local backend; the SFTP backends run
/// the same reader in the app's `LeoBrowserUploadReaderContractTests`.
struct LeoBrowserUploadReaderTests {
    private func code(_ body: () async throws -> Void) async -> LeoBrowserError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? LeoBrowserError
        }
    }

    @Test func resolvesRelativeAndAbsoluteInsideWorkspace() async throws {
        let workspace = try LeoUploadSandbox()
        defer { workspace.remove() }
        try workspace.file("docs/a.pdf", "%PDF")
        try workspace.file("b.png", "PNG!")
        try workspace.file("notes", "plain")

        let files = try await workspace.reader().read(["docs/a.pdf", "./docs/../b.png", workspace.root + "/docs/./../notes"])

        #expect(files.map(\.name) == ["a.pdf", "b.png", "notes"])
        #expect(files.map(\.workspacePath) == ["docs/a.pdf", "b.png", "notes"])
        #expect(files.map(\.data) == [Data("%PDF".utf8), Data("PNG!".utf8), Data("plain".utf8)])
        #expect(files.map(\.mimeType) == ["application/pdf", "image/png", "application/octet-stream"])
    }

    @Test(arguments: [
        ("../x", "outside the workspace"), ("/etc/hosts", "outside the workspace"), ("docs/../../x", "outside the workspace"),
        ("..", "outside the workspace"), ("/", "outside the workspace"), (".", "the workspace folder"), ("", "the workspace folder"),
    ])
    func rejectsPathsEscapingWorkspace(path: String, reason: String) async throws {
        let workspace = try LeoUploadSandbox()
        defer { workspace.remove() }
        let opened = LeoAccessCounter()

        let error = await code { _ = try await workspace.reader(counting: opened).read(["ok.txt", path]) }

        #expect(error?.code == .invalidArgs, "\(path)")
        #expect(error?.message.contains(reason) == true, "\(path): \(String(describing: error))")
        #expect(opened.count == 0, "refused before connecting")
    }

    @Test func aSiblingFolderSharingTheWorkspacePrefixIsOutside() async throws {
        let workspace = try LeoUploadSandbox()
        defer { workspace.remove() }
        let sibling = workspace.root + "-other/a.txt"

        let error = await code { _ = try await workspace.reader().read([sibling]) }

        #expect(error?.code == .invalidArgs)
        #expect(error?.message.contains("outside the workspace") == true)
    }

    @Test func noWorkspaceIsAClearError() async {
        for workspace in [nil, "", "relative/ws"] as [String?] {
            let reader = LeoBrowserUploadReader(makeAccess: { LeoFileAccessor.local() }, workspace: { workspace })
            let error = await code { _ = try await reader.read(["a.txt"]) }
            #expect(error?.code == .noSuchFile, "\(String(describing: workspace))")
            #expect(error?.message == "This agent has no workspace, so there are no files to upload")
        }
        let error = await code { _ = try await LeoBrowserUploadReader.noWorkspace.read(["a.txt"]) }
        #expect(error?.code == .noSuchFile)
    }

    @Test func missingPathIsNoSuchFileNamingThePath() async throws {
        let workspace = try LeoUploadSandbox()
        defer { workspace.remove() }
        try workspace.file("a.txt", "a")

        let error = await code { _ = try await workspace.reader().read(["a.txt", "docs/missing.txt"]) }

        #expect(error?.code == .noSuchFile)
        #expect(error?.message == "No file at docs/missing.txt in the workspace")
    }

    @Test func overTotalCapIsInvalidArgs() async throws {
        let workspace = try LeoUploadSandbox()
        defer { workspace.remove() }
        try workspace.file("a.txt", "12345")
        try workspace.file("b.txt", "123456")
        let reader = workspace.reader(maximumTotalBytes: 10)

        let error = await code { _ = try await reader.read(["a.txt", "b.txt"]) }

        #expect(error?.code == .invalidArgs)
        #expect(error?.message.contains("upload fewer or smaller files") == true)
        #expect(try await reader.read(["b.txt"]).map(\.data) == [Data("123456".utf8)], "within the cap on its own")
    }

    @Test func folderIsInvalidArgs() async throws {
        let workspace = try LeoUploadSandbox()
        defer { workspace.remove() }
        try workspace.file("docs/a.txt", "a")

        let error = await code { _ = try await workspace.reader().read(["docs"]) }

        #expect(error?.code == .invalidArgs)
        #expect(error?.message == "docs is a folder; folder uploads aren't supported")
    }

    @Test func aLostConnectionIsFileError() async {
        let reader = LeoBrowserUploadReader(makeAccess: { throw LeoFileAccessError.disconnected }, workspace: { "/ws" })
        let error = await code { _ = try await reader.read(["a.txt"]) }
        #expect(error?.code == .fileError)
        #expect(error?.message.contains("connection") == true)
    }

    @Test func closesItsAccessWhetherOrNotTheReadSucceeds() async throws {
        let workspace = try LeoUploadSandbox()
        defer { workspace.remove() }
        try workspace.file("a.txt", "a")
        let access = LeoClosingAccess()
        let reader = LeoBrowserUploadReader(makeAccess: { access }, workspace: { workspace.root })

        _ = try await reader.read(["a.txt"])
        _ = await code { _ = try await reader.read(["missing.txt"]) }

        #expect(access.closes == 2)
    }
}

/// A temp workspace for upload tests.
struct LeoUploadSandbox {
    let root: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leo-uploads-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url.resolvingSymlinksInPath().path
    }

    func file(_ relative: String, _ contents: String) throws {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    }

    func reader(counting counter: LeoAccessCounter? = nil, maximumTotalBytes: UInt64 = LeoBrowserUploadReader.defaultMaximumTotalBytes) -> LeoBrowserUploadReader {
        let root = root
        return LeoBrowserUploadReader(
            makeAccess: {
                counter?.increment()
                return LeoFileAccessor.local()
            },
            workspace: { root }, maximumTotalBytes: maximumTotalBytes
        )
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// Counts how many accesses a reader opened.
final class LeoAccessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() { lock.withLock { value += 1 } }
}

/// The local backend, counting `close()` calls.
private final class LeoClosingAccess: LeoFileAccess, @unchecked Sendable {
    private let base = LeoFileAccessor.local()
    private let lock = NSLock()
    private var closeCount = 0

    var closes: Int { lock.withLock { closeCount } }

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }

    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }

    func close() async { lock.withLock { closeCount += 1 } }
}
