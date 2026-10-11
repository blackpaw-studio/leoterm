import Testing

@testable import Ghostty

/// Which files the pane previews rather than reads as text (B-278): an
/// extension allowlist, never UTType conformance (`.ts` isn't a movie).
struct LeoFilePreviewKindTests {
    @Test(arguments: [
        ("a.png", LeoFilePreviewKind.image), ("a.JPG", .image), ("a.jpeg", .image), ("a.heic", .image),
        ("a.webp", .image), ("a.gif", .image),
        ("a.mp4", .movie), ("a.mov", .movie), ("a.M4V", .movie),
        ("a.pdf", .quickLook), ("a.docx", .quickLook), ("a.xlsx", .quickLook),
        ("README.md", .rendered(.markdown)), ("a.markdown", .rendered(.markdown)), ("a.svg", .rendered(.svg)),
        ("a.ts", .text), ("a.key", .text), ("a.txt", .text), ("a.unknownext", .text), ("Makefile", .text), (".png", .text),
    ])
    func classifiesByAllowlist(_ name: String, _ expected: LeoFilePreviewKind) {
        #expect(LeoFilePreviewKind(path: "/w/" + name) == expected)
    }

    @Test func onlyMediaAndDocumentsAreFetched() {
        #expect(LeoFilePreviewKind.image.isFetched)
        #expect(LeoFilePreviewKind.movie.isFetched)
        #expect(LeoFilePreviewKind.quickLook.isFetched)
        #expect(!LeoFilePreviewKind.text.isFetched)
        #expect(!LeoFilePreviewKind.rendered(.markdown).isFetched)
    }

    @Test func typeNameFallsBack() {
        #expect(LeoFilePreviewKind.typeName(forPath: "/w/a.zip").localizedCaseInsensitiveContains("zip"))
        #expect(LeoFilePreviewKind.typeName(forPath: "/w/a.qqqzz") == "This File")
        #expect(LeoFilePreviewKind.typeName(forPath: "/w/Makefile") == "This File")
    }
}
