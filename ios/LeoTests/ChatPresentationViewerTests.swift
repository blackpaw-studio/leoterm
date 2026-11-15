import LeoKit
import Testing
import UIKit

@testable import Leo

@MainActor
struct ChatPresentationViewerTests {
    private func attachment(_ name: String, mime: String) -> LeoChatAttachment {
        LeoChatAttachment(id: "a", filename: name, mime: mime, bytes: 3)
    }

    private func tempFile(_ name: String) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
        try Data("# hi".utf8).write(to: url)
        return url
    }

    @Test func markdownWithReadableFileOpensTheNativeViewer() throws {
        let url = try tempFile("a.md")
        let controller = ChatPresentation.viewer(for: attachment("a.md", mime: "text/markdown"), url: url)
        let nav = try #require(controller as? UINavigationController)
        #expect(nav.topViewController is ChatMarkdownViewController)
    }

    @Test func otherFilesOpenInQuickLook() throws {
        let url = try tempFile("a.pdf")
        #expect(ChatPresentation.viewer(for: attachment("a.pdf", mime: "application/pdf"), url: url) is ChatQuickLookController)
    }

    @Test func unreadableMarkdownFallsBackToQuickLook() {
        let missing = URL.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).md")
        #expect(ChatPresentation.viewer(for: attachment("a.md", mime: "text/markdown"), url: missing) is ChatQuickLookController)
    }
}
