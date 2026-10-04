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

    /// Only the first window opens it, through the opener.
    @Test func opensThePathOnceForTheFirstWindow() {
        let fixture = LeoOpenFileFixture(path: "/tmp/a.txt")
        var opened: [String] = []

        fixture.windowCameUp { opened.append($0) }
        fixture.windowCameUp { opened.append($0) }

        #expect(opened == ["/tmp/a.txt"])
    }

    /// With a remote host selected the window's file access refuses local
    /// files; the fixture still opens its file on this Mac, and takes its
    /// path literally (a name ending in `:12` is not a line number).
    @Test func theRuntimeOpensTheFileLocallyAndLiterallyWhateverHostIsSelected() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let defaults = LeoInMemoryDefaults()
            let activity = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
            let runtime = LeoRuntime(daemon: QuitReviewDaemon(), cli: .recordingForTests(), activitySource: activity, defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner())
            let session = runtime.registry.makeSession(defaults: defaults, makeFileAccess: { _ in
                throw LeoFileAccessError.unavailable(reason: "Leo is connected to work, not localhost")
            })
            let path = try sandbox.file("foo:12", "twelve")
            var errors: [String] = []

            await runtime.openFixtureFile(path, in: session) { errors.append($0.localizedDescription) }

            #expect(errors.isEmpty)
            #expect(session.editor.document?.fileID == LeoEditorFileID(host: .local, path: path))
            #expect(session.editor.document?.text == "twelve")
            await session.editor.release()
        }
    }

    @Test func withoutAPathNoWindowOpensAnything() {
        let fixture = LeoOpenFileFixture(path: nil)
        var opened: [String] = []
        fixture.windowCameUp { opened.append($0) }
        #expect(opened.isEmpty)
    }
}
#endif
