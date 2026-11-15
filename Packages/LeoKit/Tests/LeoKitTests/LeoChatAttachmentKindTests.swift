import Testing

@testable import LeoKit

@Suite struct LeoChatAttachmentKindTests {
    private func attachment(_ name: String, mime: String = "application/octet-stream") -> LeoChatAttachment {
        LeoChatAttachment(id: "a", filename: name, mime: mime, bytes: 1)
    }

    @Test(arguments: [
        ("README.md", "application/octet-stream", true),
        ("notes.MARKDOWN", "application/octet-stream", true),
        ("x.txt", "text/markdown", true),
        ("x.txt", "TEXT/X-MARKDOWN", true),
        ("x.md.txt", "text/plain", false),
        ("x.pdf", "application/pdf", false),
    ])
    func classifiesMarkdown(name: String, mime: String, expected: Bool) {
        #expect(attachment(name, mime: mime).isMarkdown == expected)
    }
}
