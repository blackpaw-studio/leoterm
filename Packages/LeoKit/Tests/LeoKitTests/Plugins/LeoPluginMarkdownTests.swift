import Foundation
import Testing

@testable import LeoKit

struct LeoPluginMarkdownTests {
    @Test func parsesHeadingsAndParagraphs() {
        let blocks = LeoPluginMarkdown.parse("# Title\n\nhello world")
        #expect(blocks == [
            .heading(level: 1, [.text("Title")]),
            .paragraph([.text("hello world")]),
        ])
    }

    @Test func parsesEmphasisStrongAndCode() {
        let blocks = LeoPluginMarkdown.parse("a *b* **c** `d`")
        #expect(blocks == [.paragraph([
            .text("a "), .emphasis([.text("b")]), .text(" "), .strong([.text("c")]), .text(" "), .code("d"),
        ])])
    }

    @Test func parsesLists() {
        let blocks = LeoPluginMarkdown.parse("- one\n- two\n\n1. a\n2. b")
        #expect(blocks == [
            .list(ordered: false, items: [[.text("one")], [.text("two")]]),
            .list(ordered: true, items: [[.text("a")], [.text("b")]]),
        ])
    }

    @Test func parsesFencedCodeVerbatim() {
        let blocks = LeoPluginMarkdown.parse("```swift\nlet *x* = 1\n```")
        #expect(blocks == [.codeBlock("let *x* = 1")])
    }

    @Test func keepsHTTPSLinks() {
        let blocks = LeoPluginMarkdown.parse("[hi](https://example.com/a)")
        #expect(blocks == [.paragraph([.link(text: [.text("hi")], url: "https://example.com/a")])])
    }

    @Test(arguments: ["http://x.com", "javascript:void", "file:///etc/passwd", "/relative"])
    func nonHTTPSLinksBecomePlainText(url: String) {
        let blocks = LeoPluginMarkdown.parse("[hi](\(url))")
        #expect(blocks == [.paragraph([.text("hi")])])
    }

    @Test func imagesAndHTMLAreDroppedToPlainText() {
        let img = LeoPluginMarkdown.parse("![alt](https://x.com/a.png)")
        #expect(img == [.paragraph([.text("![alt](https://x.com/a.png)")])])
        let html = LeoPluginMarkdown.parse("<b>x</b>")
        #expect(html == [.paragraph([.text("<b>x</b>")])])
    }

    @Test func unterminatedMarkersStayLiteral() {
        #expect(LeoPluginMarkdown.parse("a *b") == [.paragraph([.text("a *b")])])
    }
}

struct LeoPluginMarkdownBoundsTests {
    private func steps(_ source: String) -> Int {
        let work = LeoPluginMarkdown.Work()
        _ = LeoPluginMarkdown.parse(source, work: work)
        return work.steps
    }

    @Test func unmatchedBracketsStayLinear() {
        let n = 50_000
        #expect(steps(String(repeating: "[", count: n)) <= 20 * n)
    }

    @Test func unmatchedEmphasisAndCodeStayLinear() {
        let n = 20_000
        #expect(steps(String(repeating: "*", count: n)) <= 20 * n)
        #expect(steps(String(repeating: "`a", count: n)) <= 20 * n)
        #expect(steps(String(repeating: "[a](", count: n)) <= 20 * n)
    }

    @Test func nestedLabelsStayLinear() {
        let n = 20_000
        #expect(steps(String(repeating: "[a *b* ", count: n) + "](https://x.example)") <= 20 * n * 7)
    }

    @Test func parseTruncatesSourceOverTheByteCap() {
        let big = String(repeating: "a", count: LeoPluginFrameLimits.maxMarkdownBytes + 10)
        let blocks = LeoPluginMarkdown.parse(big)
        guard case .paragraph(let inlines) = blocks.first, case .text(let text) = inlines.first else {
            Issue.record("expected one paragraph"); return
        }
        #expect(text.utf8.count == LeoPluginFrameLimits.maxMarkdownBytes)
    }

    @Test func detailRejectsMarkdownOverTheByteCap() {
        let big = String(repeating: "a", count: LeoPluginFrameLimits.maxMarkdownBytes + 1)
        let json = #"{"type":"Detail","markdown":"\#(big)"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(json.utf8))
        }
    }

    @Test func truncationNeverSplitsAMultiByteCharacter() {
        let source = String(repeating: "é", count: LeoPluginFrameLimits.maxMarkdownBytes / 2 + 5)
        let blocks = LeoPluginMarkdown.parse(source)
        guard case .paragraph(let inlines) = blocks.first, case .text(let text) = inlines.first else {
            Issue.record("expected one paragraph"); return
        }
        #expect(text.utf8.count <= LeoPluginFrameLimits.maxMarkdownBytes)
        #expect(!text.contains("\u{FFFD}"))
    }
}
