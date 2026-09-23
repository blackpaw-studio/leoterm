#if DEBUG
import Foundation
import Testing

@testable import Ghostty

/// The DEBUG-only `LEO_OPEN_FILE` hook that opens a local file in the
/// first window's editor at launch, for GUI checks past the Open File panel.
@MainActor
struct LeoOpenFileFixtureTests {
    private static let key = LeoOpenFileFixture.environmentKey

    @Test func readsAnAbsolutePathToAnExistingFile() {
        let path = LeoOpenFileFixture.path(environment: [Self.key: "/tmp/a.txt"], isFile: { $0 == "/tmp/a.txt" })
        #expect(path == "/tmp/a.txt")
    }

    @Test func ignoresMissingEmptyRelativeAndNonexistentPaths() {
        let isFile: (String) -> Bool = { _ in true }
        #expect(LeoOpenFileFixture.path(environment: [:], isFile: isFile) == nil)
        #expect(LeoOpenFileFixture.path(environment: [Self.key: ""], isFile: isFile) == nil)
        #expect(LeoOpenFileFixture.path(environment: [Self.key: "a.txt"], isFile: isFile) == nil)
        #expect(LeoOpenFileFixture.path(environment: [Self.key: "~/a.txt"], isFile: isFile) == nil)
        #expect(LeoOpenFileFixture.path(environment: [Self.key: "/tmp/gone.txt"], isFile: { _ in false }) == nil)
    }

    @Test func theDefaultCheckAcceptsFilesButNotFoldersOrMissingPaths() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)

        #expect(LeoOpenFileFixture.isRegularFile(file.path))
        #expect(!LeoOpenFileFixture.isRegularFile(folder.path))
        #expect(!LeoOpenFileFixture.isRegularFile(folder.appendingPathComponent("gone").path))
    }

    /// Only the first window opens it, as a local file, through the opener.
    @Test func opensThePathOnceForTheFirstWindowAsALocalFile() {
        let fixture = LeoOpenFileFixture(path: "/tmp/a.txt")
        var opened: [(String, LeoEditorAgentContext)] = []
        let opener: (String, LeoEditorAgentContext) -> Void = { opened.append(($0, $1)) }

        fixture.windowCameUp(open: opener)
        fixture.windowCameUp(open: opener)

        #expect(opened.map(\.0) == ["/tmp/a.txt"])
        #expect(opened.map(\.1) == [LeoEditorAgentContext(host: .local, name: nil, workspace: nil)])
    }

    @Test func withoutAPathNoWindowOpensAnything() {
        let fixture = LeoOpenFileFixture(path: nil)
        var opened: [String] = []
        fixture.windowCameUp { text, _ in opened.append(text) }
        #expect(opened.isEmpty)
    }
}
#endif
