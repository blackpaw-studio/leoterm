import Foundation
import Testing

@testable import LeoKit

struct LeoChatTextTests {
    /// Every linked run as (visible text, URL).
    static func links(_ text: String) -> [(text: String, url: URL)] {
        let attributed = LeoChatText.attributed(text)
        return attributed.runs.compactMap { run in
            run.link.map { (String(attributed[run.range].characters), $0) }
        }
    }

    @Test func aBareURLIsLinked() {
        let links = Self.links("go to https://example.com now")
        #expect(links.count == 1)
        #expect(links.first?.text == "https://example.com")
        #expect(links.first?.url == URL(string: "https://example.com"))
    }

    @Test func aMarkdownLinkIsKept() {
        let links = Self.links("see [the docs](https://example.com/docs) here")
        #expect(links.count == 1)
        #expect(links.first?.text == "the docs")
        #expect(links.first?.url == URL(string: "https://example.com/docs"))
    }

    @Test func aURLInsideInlineCodeIsNotLinked() {
        #expect(Self.links("run `curl https://example.com` first").isEmpty)
    }

    @Test func aURLInsideAMarkdownLinkIsNotDoubleLinked() {
        let links = Self.links("[https://example.com](https://example.com/x)")
        #expect(links.count == 1)
        #expect(links.first?.url == URL(string: "https://example.com/x"))
    }

    @Test func mailtoIsLinked() {
        let links = Self.links("write to [me](mailto:evan@example.com) or evan@example.com")
        #expect(links.count == 2)
        #expect(links.allSatisfy { $0.url.scheme == "mailto" })
    }

    @Test(arguments: ["[x](file:///etc/passwd)", "[x](javascript:alert(1))", "file:///etc/passwd"])
    func otherSchemesAreNotLinked(_ text: String) {
        #expect(Self.links(text).isEmpty)
    }

    @Test func aRejectedMarkdownLinkKeepsItsVisibleText() {
        let attributed = LeoChatText.attributed("[click](javascript:alert(1))")
        #expect(String(attributed.characters) == "click")
    }

    @Test func trailingPunctuationIsNotPartOfTheLink() {
        let links = Self.links("see https://x.com.")
        #expect(links.first?.text == "https://x.com")
        #expect(links.first?.url == URL(string: "https://x.com"))
    }

    @Test func invalidMarkdownFallsBackToPlainTextAndStillAutolinks() {
        let text = "[broken](  https://example.com"
        let attributed = LeoChatText.attributed(text)
        #expect(String(attributed.characters).contains("https://example.com"))
        #expect(Self.links(text).map(\.url) == [URL(string: "https://example.com")!])
    }

    @Test func plainTextIsUnchanged() {
        #expect(String(LeoChatText.attributed("just words\nacross lines").characters) == "just words\nacross lines")
    }
}
