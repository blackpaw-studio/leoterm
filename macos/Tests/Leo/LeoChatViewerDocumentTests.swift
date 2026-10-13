import Testing

@testable import Ghostty

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
