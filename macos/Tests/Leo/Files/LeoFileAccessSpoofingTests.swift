import Foundation
import Testing

@testable import Ghostty

/// A file whose name tries to pass for the app's own words -- ending its
/// quote, adding a line, reordering the sentence -- sent through every
/// backend and every place an error is shown. Whatever the source, the
/// error reads the same: cleaned once, when it is rendered.
@Suite(LeoSSHEndToEnd.trait)
struct LeoFileAccessSpoofingTests {
    /// A curly quote and a U+2E42 lookalike, a line break, an RTL override.
    static let spoof = "x”\n\u{202E}Reconnect\u{2E42}.txt"
    /// `spoof` as the app shows it, isolated in its own direction.
    static let shown = "\u{2068}x\" Reconnect\".txt\u{2069}"

    @Test(arguments: LeoFileBackendKind.allCases)
    func aSpoofingNameReadsAsANameFromEveryBackend(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, access in
            let file = try sandbox.file(Self.spoof, "x")
            let missing = sandbox.path(Self.spoof + "2")

            let notAFolder = await #expect(throws: LeoFileAccessError.self) { try await access.list(file) }
            let notFound = await #expect(throws: LeoFileAccessError.self) { try await access.stat(missing) }

            #expect(notAFolder?.localizedDescription == "“\(Self.shown)” isn’t a folder.")
            #expect(notFound?.localizedDescription == "“\u{2068}x\" Reconnect\".txt2\u{2069}” couldn’t be found.")
        }
    }

    /// Foundation's own description embeds the raw name in its own quotes.
    @Test func foundationsDescriptionOfALocalFailureIsCleanedToo() throws {
        let path = "/d/" + Self.spoof
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: [NSFilePathErrorKey: path])
        #expect(cocoa.localizedDescription.contains(Self.spoof))

        let description = LeoLocalFileBackend.error(cocoa, path: path).localizedDescription

        let prefix = "Couldn’t access “\(Self.shown)”: \u{2068}"
        #expect(description.hasPrefix(prefix))
        #expect(description.hasSuffix("\u{2069}."))
        let foundation = description.dropFirst(prefix.count).dropLast(2)
        #expect(foundation.contains("x\" Reconnect\".txt"))
        #expect(!foundation.contains { "“”\n\u{202E}\u{2068}\u{2069}".contains($0) })
    }

    /// The REMOVE + RENAME fallback names the temp file it kept.
    @Test func theTempNameARenameKeptIsCleanedToo() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let destination = try sandbox.file("a.txt", "old")
        let backend = LeoSFTPFileBackend(
            session: LeoSFTPSession(launcher: LeoSFTPTestServer.launcher()), options: .init(usesPosixRename: false)
        )

        let error = await #expect(throws: LeoFileAccessError.self) {
            try await backend.replace(destination, with: sandbox.path(Self.spoof))
        }
        await backend.close()

        let description = try #require(error?.localizedDescription)
        #expect(description.hasPrefix("Couldn’t access “\u{2068}a.txt\u{2069}”: the original was removed"))
        #expect(description.hasSuffix("they were kept as “\(Self.shown)”."))
    }

    /// Whatever the transport failed to decode is described, then cleaned.
    @Test func theTransportsDescriptionOfAFailureIsCleanedToo() {
        struct Strange: Error, CustomStringConvertible {
            var description: String { LeoFileAccessSpoofingTests.spoof }
        }
        let error = LeoFileAccessError.protocolError(LeoSFTPTransport.describe(Strange()))
        #expect(error.localizedDescription == "The file server sent an unexpected response (\(Self.shown)).")
        #expect(LeoFileAccessError.protocolError(LeoSFTPTransport.describe(LeoSFTPCodecError.badLength(0))).localizedDescription
            == "The file server sent an unexpected response (bad packet length 0).")
    }

    /// A server's message about a spoofing name: both are cleaned and
    /// isolated, and the server's is labelled as the server's.
    @Test func aServersMessageAboutASpoofingNameIsCleanedToo() {
        let status = LeoSFTPStatus(code: .failure, message: "done”\nFile access unavailable\u{1F676}")
        let error = LeoSFTPClient.error(for: status, path: "/d/" + Self.spoof)
        #expect(error.localizedDescription
            == "Couldn’t access “\(Self.shown)”: the server said “\u{2068}done\" File access unavailable\"\u{2069}”.")
    }
}

/// The fakes: an error from any `LeoFileAccess` reaches the browser and
/// the editor already rendered, and neither cleans or wraps it again.
@MainActor
extension LeoFileAccessSpoofingTests {
    private static var spoofError: LeoFileAccessError {
        .failed(path: "/w/" + spoof, reason: LeoSFTPServerText.quoted("no\n\u{202E}way”"))
    }

    @Test func theBrowserShowsARenderedErrorAsIs() async {
        let error = Self.spoofError
        #expect(LeoWorkspaceBrowserModel.message(for: error) == error.localizedDescription)
        #expect(error.localizedDescription
            == "Couldn’t access “\(Self.shown)”: the server said “\u{2068}no way\"\u{2069}”.")

        let browser = LeoWorkspaceBrowserModel(
            makeAccess: { _ in LeoFileAccessor.local() },
            openFile: { _ in throw error }
        )
        await browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: "/tmp"))
        await browser.openFile("/w/" + Self.spoof)
        #expect(browser.openError == error.localizedDescription)
        await browser.close()
    }

    @Test func theBrowserStillCleansErrorsThatAreNotItsOwn() {
        struct Foreign: LocalizedError {
            var errorDescription: String? { LeoFileAccessSpoofingTests.spoof }
        }
        #expect(LeoWorkspaceBrowserModel.message(for: Foreign()) == "x\" Reconnect\".txt")
    }

    @Test func theEditorShowsARenderedErrorAsIs() async throws {
        try await withLeoFileSandbox(.local) { sandbox, access in
            let path = try sandbox.file("a.txt", "one")
            let failing = LeoFailingWriteAccess(base: access, error: Self.spoofError)
            let document = try await LeoEditorDocument.open(LeoEditorFileID(host: .local, path: path), access: failing, policy: .default)
            document.edit("two")

            let expected = Self.spoofError.localizedDescription
            #expect(await document.save() == .failed(expected))
            #expect(document.errorMessage == expected)
            #expect(LeoEditorBanner.current(for: document)?.message == expected)
        }
    }
}

/// `base`, except every write throws `error`.
private struct LeoFailingWriteAccess: LeoFileAccess {
    let base: any LeoFileAccess
    let error: LeoFileAccessError

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat { throw error }
    func close() async { await base.close() }
}
