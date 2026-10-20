import Foundation
import Testing

@testable import Ghostty

struct LeoSelfLinkTests {
    private static let paths = LeoInstallPaths(
        home: URL(fileURLWithPath: "/home/test", isDirectory: true),
        bundleURL: URL(fileURLWithPath: "/Applications/Leo.app")
    )
    private static let link = "/home/test/.leo/app/bin/leo"
    private static let helper = "/Applications/Leo.app/Contents/Helpers/leo"

    private func makeFileSystem(helperPresent: Bool = true) -> LeoInMemoryFileSystem {
        let fileSystem = LeoInMemoryFileSystem()
        if helperPresent { fileSystem.addFile(Self.helper, "bin", mode: 0o755) }
        return fileSystem
    }

    private func refresh(_ fileSystem: LeoInMemoryFileSystem, inApplications: Bool = true) throws -> LeoSelfLink.Outcome {
        try LeoSelfLink(paths: Self.paths, fileSystem: fileSystem).refresh(isInApplications: inApplications)
    }

    @Test func createsTheBinDirectoryAndPointsTheLinkAtTheBundledHelper() throws {
        let fileSystem = makeFileSystem()

        #expect(try refresh(fileSystem) == .linked)

        #expect(fileSystem.ops == [
            .createDirectory("/home/test/.leo/app/bin", mode: 0o755),
            .symlink("/home/test/.leo/app/bin/.leo.t1.tmp", target: Self.helper),
            .rename("/home/test/.leo/app/bin/.leo.t1.tmp", Self.link)
        ])
        #expect(fileSystem.kind(at: URL(fileURLWithPath: Self.link)) == .symlink(target: Self.helper))
    }

    @Test func doesNothingWhenTheLinkIsAlreadyCorrect() throws {
        let fileSystem = makeFileSystem()
        fileSystem.addSymlink(Self.link, to: Self.helper)

        #expect(try refresh(fileSystem) == .alreadyCorrect)
        #expect(fileSystem.ops.isEmpty)
    }

    @Test func repointsAStaleLinkAtomicallyAfterTheAppMovedOrUpdated() throws {
        let fileSystem = makeFileSystem()
        fileSystem.addSymlink(Self.link, to: "/Users/old/Downloads/Leo.app/Contents/Helpers/leo")

        #expect(try refresh(fileSystem) == .linked)

        #expect(fileSystem.ops == [
            .symlink("/home/test/.leo/app/bin/.leo.t1.tmp", target: Self.helper),
            .rename("/home/test/.leo/app/bin/.leo.t1.tmp", Self.link)
        ])
    }

    @Test func skipsWhenTheAppIsNotInApplications() throws {
        let fileSystem = makeFileSystem()
        #expect(try refresh(fileSystem, inApplications: false) == .skipped(.notInApplications))
        #expect(fileSystem.ops.isEmpty)
    }

    @Test func skipsWhenTheBundleHasNoHelper() throws {
        let fileSystem = makeFileSystem(helperPresent: false)
        #expect(try refresh(fileSystem) == .skipped(.helperMissing))
        #expect(fileSystem.ops.isEmpty)
    }

    @Test(arguments: [LeoPathKind.file, .directory])
    func neverReplacesARealFileOrDirectoryAtTheLinkPath(kind: LeoPathKind) throws {
        let fileSystem = makeFileSystem()
        if kind == .file { fileSystem.addFile(Self.link) } else { fileSystem.addDirectory(Self.link) }

        #expect(try refresh(fileSystem) == .skipped(.occupied))
        #expect(fileSystem.ops.isEmpty)
    }

    @Test func surfacesAFailedSwapAndLeavesTheOldLinkInPlace() {
        let fileSystem = makeFileSystem()
        fileSystem.addSymlink(Self.link, to: "/old")
        fileSystem.failNext("replaceSymlink", at: Self.link)

        #expect(throws: LeoFileSystemError.self) { try refresh(fileSystem) }
        #expect(fileSystem.kind(at: URL(fileURLWithPath: Self.link)) == .symlink(target: "/old"))
    }
}
