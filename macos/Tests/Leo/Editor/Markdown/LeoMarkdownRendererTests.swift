import AppKit
import Testing

@testable import Ghostty

/// Native Markdown rendering (B-278): headings, code, GitHub tables, lists
/// and quotes as TextKit 1 blocks; links only to the web or mail; images
/// as alt text, never fetched.
@MainActor
struct LeoMarkdownRendererTests {
    private let renderer = LeoMarkdownRenderer()

    private func attribute<T>(_ key: NSAttributedString.Key, of text: String, in rendered: NSAttributedString) -> T? {
        let range = (rendered.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        return rendered.attribute(key, at: range.location, effectiveRange: nil) as? T
    }

    private func style(of text: String, in rendered: NSAttributedString) -> NSParagraphStyle? {
        attribute(.paragraphStyle, of: text, in: rendered)
    }

    @Test func headingsScale() throws {
        let rendered = renderer.render("# One\n\n## Two\n\nbody")
        let one: NSFont = try #require(attribute(.font, of: "One", in: rendered))
        let two: NSFont = try #require(attribute(.font, of: "Two", in: rendered))
        let body: NSFont = try #require(attribute(.font, of: "body", in: rendered))
        #expect(one.pointSize > two.pointSize)
        #expect(two.pointSize > body.pointSize)
        #expect(rendered.string == "One\nTwo\nbody")
    }

    @Test func fencedCodeMonospacedInTextBlock() throws {
        let rendered = renderer.render("text\n\n```swift\nlet x = 1\nlet y = 2\n```\n")
        let font: NSFont = try #require(attribute(.font, of: "let y", in: rendered))
        #expect(font.isFixedPitch)
        let first = try #require(style(of: "let x", in: rendered)?.textBlocks.first)
        let second = try #require(style(of: "let y", in: rendered)?.textBlocks.first)
        #expect(first === second)
        #expect(first.backgroundColor != nil)
        #expect(style(of: "text", in: rendered)?.textBlocks.isEmpty == true)
    }

    @Test func gfmTableIsTextTable() throws {
        let rendered = renderer.render("| A | B |\n|---|---|\n| a1 | b1 |\n| a2 | b2 |\n")
        var cells: [(row: Int, column: Int, text: String)] = []
        var tables: Set<ObjectIdentifier> = []
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else { return }
            tables.insert(ObjectIdentifier(cell.table))
            let text = (rendered.string as NSString).substring(with: range).trimmingCharacters(in: .newlines)
            cells.append((cell.startingRow, cell.startingColumn, text))
        }
        #expect(tables.count == 1)
        #expect(cells.map(\.text) == ["A", "B", "a1", "b1", "a2", "b2"])
        #expect(cells.map(\.row) == [0, 0, 1, 1, 2, 2])
        #expect(cells.map(\.column) == [0, 1, 0, 1, 0, 1])
    }

    @Test func twoTablesNumberTheirRowsApart() throws {
        let rendered = renderer.render("| A |\n|---|\n| a |\n\n| B |\n|---|\n| b |\n")
        let lastCell = try #require(style(of: "b", in: rendered)?.textBlocks.first as? NSTextTableBlock)
        #expect(lastCell.startingRow == 1)
    }

    @Test func orderedListNumbers() throws {
        let rendered = renderer.render("1. one\n2. two\n   - nested\n")
        #expect(rendered.string.contains("1.\tone"))
        #expect(rendered.string.contains("2.\ttwo"))
        #expect(rendered.string.contains("◦\tnested"))
        let outer = try #require(style(of: "one", in: rendered))
        let inner = try #require(style(of: "nested", in: rendered))
        #expect(outer.textLists.count == 1)
        #expect(inner.textLists.count == 2)
        #expect(inner.headIndent > outer.headIndent)
    }

    @Test func quoteHasBorderedBlock() throws {
        let rendered = renderer.render("> one\n>\n> two\n")
        let first = try #require(style(of: "one", in: rendered)?.textBlocks.first)
        let second = try #require(style(of: "two", in: rendered)?.textBlocks.first)
        #expect(first === second)
        #expect(first.width(for: .border, edge: .minX) > 0)
    }

    @Test func onlyWebLinksKept() {
        let rendered = renderer.render("[web](https://example.com) [mail](mailto:a@b.c) [js](javascript:alert(1)) [file](file:///etc/passwd)")
        let web: URL? = attribute(.link, of: "web", in: rendered)
        let mail: URL? = attribute(.link, of: "mail", in: rendered)
        let script: URL? = attribute(.link, of: "js", in: rendered)
        let file: URL? = attribute(.link, of: "file", in: rendered)
        #expect(web == URL(string: "https://example.com"))
        #expect(mail == URL(string: "mailto:a@b.c"))
        #expect(script == nil)
        #expect(file == nil)
    }

    @Test func imageIsAltTextNoFetch() {
        let rendered = renderer.render("before ![a cat](https://example.com/cat.png) after")
        #expect(rendered.string == "before a cat after")
        var hasAttachment = false
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if value != nil { hasAttachment = true }
        }
        #expect(!hasAttachment)
        let link: URL? = attribute(.link, of: "a cat", in: rendered)
        #expect(link == nil)
    }

    @Test func malformedNeverThrows() {
        for input in ["", "|||\n|-|\n", "```\nunterminated", "[a](", "> > > >", String(repeating: "*", count: 5000), "\u{0}\u{FFFF}"] {
            _ = renderer.render(input)
        }
        #expect(renderer.render("").length == 0)
    }
}
