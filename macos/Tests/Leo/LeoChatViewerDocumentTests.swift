import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Which preview kind a chat attachment gets: filename extension first (as
/// the editor does), then its MIME type; nil means "neither knows it".
struct LeoChatViewerKindTests {
    @Test(arguments: [
        ("shot", "image/png", LeoFilePreviewKind.image),
        ("clip", "video/quicktime", .movie),
        ("x", "application/pdf", .quickLook),
        ("notes", "text/markdown", .rendered(.markdown)),
        ("d", "IMAGE/SVG+XML; charset=utf-8", .rendered(.svg)),
        ("a.png", "application/pdf", .image),
    ])
    func resolvesExtensionThenMime(_ filename: String, _ mime: String, _ expected: LeoFilePreviewKind) {
        #expect(LeoChatViewerKind.known(filename: filename, mime: mime) == expected)
    }

    @Test(arguments: [("a.json", "application/json"), ("blob", "application/octet-stream"), ("blob", "")])
    func isNilWhenNeitherKnowsIt(_ filename: String, _ mime: String) {
        #expect(LeoChatViewerKind.known(filename: filename, mime: mime) == nil)
    }
}

/// Turning a downloaded attachment into something the viewer can show, or
/// nil when the click should open the default app instead.
struct LeoChatViewerDocumentTests {
    private func load(_ filename: String, mime: String = "application/octet-stream", bytes: Data?) async throws -> LeoChatViewerDocument? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(filename)
        if let bytes { try bytes.write(to: url) }
        let attachment = LeoChatAttachment(id: "a1", filename: filename, mime: mime, bytes: bytes?.count ?? 0)
        return await LeoChatViewerDocument.load(attachment: attachment, url: url)
    }

    @Test func markdownIsRenderedFromItsText() async throws {
        let doc = try #require(await load("notes.md", bytes: Data("# hi".utf8)))
        #expect(doc.content == .markdown)
        #expect(doc.body == .text("# hi", .rendered(.markdown)))
        #expect(doc.filename == "notes.md")
        #expect(doc.attachmentID == "a1")
    }

    @Test func knownTextExtensionShowsAsText() async throws {
        let doc = try #require(await load("data.json", mime: "application/json", bytes: Data("{}".utf8)))
        #expect(doc.content == .text)
    }

    @Test func unknownExtensionWithUTF8TextShowsAsText() async throws {
        let doc = try #require(await load("LOG", bytes: Data("line one\n".utf8)))
        #expect(doc.content == .text)
        #expect(doc.body == .text("line one\n", .text))
    }

    @Test func unknownExtensionWithABinaryByteOpensExternally() async throws {
        #expect(try await load("blob.bin", bytes: Data([0x41, 0x00, 0x42])) == nil)
    }

    @Test func invalidUTF8OpensExternally() async throws {
        #expect(try await load("blob.dat", bytes: Data([0xFF, 0xFE, 0xFD])) == nil)
    }

    @Test func invalidUTF8MarkdownOpensExternally() async throws {
        #expect(try await load("bad.md", bytes: Data([0xFF, 0xFE, 0xFD])) == nil)
    }

    @Test func theDisplayNameDropsBidiOverridesButKindStillUsesTheRealName() async throws {
        let spoofed = "invoice\u{202E}fdp.png"
        let doc = try #require(await load(spoofed, mime: "image/png", bytes: nil))
        #expect(!doc.displayName.unicodeScalars.contains("\u{202E}"))
        #expect(doc.filename == spoofed)
        #expect(doc.body == .file(.image))
    }

    @Test func imageIsShownWithoutReadingTheFile() async throws {
        let doc = try #require(await load("shot.png", mime: "image/png", bytes: nil))
        #expect(doc.content == .image(doc.url))
    }

    @Test func pdfByMimeIsShownThroughQuickLook() async throws {
        let doc = try #require(await load("report", mime: "application/pdf", bytes: nil))
        #expect(doc.content == .quickLook(doc.url))
    }

    @Test func missingTextFileOpensExternally() async throws {
        #expect(try await load("gone.md", bytes: nil) == nil)
    }
}
