import Foundation
import Testing

@testable import LeoKit

@Suite struct LeoMarkdownParserTests {
    private func parse(_ s: String) -> [LeoMarkdownBlock] { LeoMarkdownDocument.parse(s).blocks }
    private func plain(_ t: String, _ traits: LeoMarkdownRun.Traits = [], link: URL? = nil) -> LeoMarkdownRun {
        LeoMarkdownRun(text: t, traits: traits, link: link)
    }
    private func paragraphRuns(_ s: String) -> [LeoMarkdownRun] {
        guard case .paragraph(let runs)? = parse(s).first else { return [] }
        return runs
    }

    @Test func headingsOneThroughSix() {
        let md = (1...6).map { String(repeating: "#", count: $0) + " " + ["A", "B", "C", "D", "E", "F"][$0 - 1] }.joined(separator: "\n\n")
        let expected: [LeoMarkdownBlock] = (1...6).map { .heading(level: $0, [plain(["A", "B", "C", "D", "E", "F"][$0 - 1])]) }
        #expect(parse(md) == expected)
    }

    @Test func inlineTraits() {
        #expect(paragraphRuns("*em*") == [plain("em", .emphasis)])
        #expect(paragraphRuns("**strong**") == [plain("strong", .strong)])
        #expect(paragraphRuns("`code`") == [plain("code", .code)])
        #expect(paragraphRuns("~~del~~") == [plain("del", .strikethrough)])
        #expect(paragraphRuns("***both***") == [plain("both", [.strong, .emphasis])])
    }

    @Test func nestedAndOrderedLists() {
        let blocks = parse("- a\n  - b\n\n1. x")
        guard blocks.count == 2, case .list(let outer) = blocks[0], case .list(let ordered) = blocks[1] else {
            Issue.record("expected two lists, got \(blocks)"); return
        }
        #expect(!outer.isOrdered)
        #expect(outer.items.count == 1)
        #expect(outer.items[0].first == .paragraph([plain("a")]))
        guard case .list(let inner)? = outer.items[0].last else {
            Issue.record("expected nested list"); return
        }
        #expect(inner.items == [[.paragraph([plain("b")])]])
        #expect(ordered.isOrdered)
        #expect(ordered.start == 1)
    }

    @Test func orderedListStart() {
        guard case .list(let list)? = parse("3. x\n4. y").first else {
            Issue.record("expected list"); return
        }
        #expect(list.start == 3)
        #expect(list.items.count == 2)
    }

    @Test func fencedCodeKeepsLanguageAndExactText() {
        #expect(parse("```swift\nlet a = 1\n  let b = 2\n```") == [.code(language: "swift", text: "let a = 1\n  let b = 2")])
    }

    @Test func quoteAndRule() {
        #expect(parse("> q") == [.quote([.paragraph([plain("q")])])])
        #expect(parse("---") == [.rule])
    }

    @Test func tableAlignmentCellsAndRaggedRows() {
        let md = "| A | B | C |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n| 4 |"
        guard case .table(let t)? = parse(md).first else {
            Issue.record("expected table"); return
        }
        #expect(t.alignments == [.leading, .center, .trailing])
        #expect(t.header == [[plain("A")], [plain("B")], [plain("C")]])
        #expect(t.rows.count == 2)
        #expect(t.rows[0] == [[plain("1")], [plain("2")], [plain("3")]])
        #expect(t.rows[1].count == 3)
        #expect(t.rows[1][0] == [plain("4")])
    }

    @Test(arguments: [
        ("http://a.com", true), ("https://a.com", true), ("HTTPS://a.com", true), ("mailto:a@b.com", true),
        ("javascript:alert(1)", false), ("file:///etc/passwd", false), ("tel:555", false), ("foo.md", false),
    ])
    func linkFiltering(url: String, kept: Bool) {
        let runs = paragraphRuns("[label](\(url))")
        #expect(runs.map(\.text).joined() == "label")
        #expect(runs.allSatisfy { ($0.link != nil) == kept })
    }

    @Test func imageBecomesAltText() {
        #expect(paragraphRuns("![alt](https://x/y.png)") == [plain("alt", .image)])
    }

    @Test func malformedInputNeverCrashes() {
        #expect(parse("").isEmpty)
        #expect(parse("```\nopen") == [.code(language: nil, text: "open")])
        let deep = String(repeating: ">", count: 200) + " x"
        #expect(!parse(deep).isEmpty)
        #expect(!parse("a\u{0}b\u{1}c\u{7f}").isEmpty)
        #expect(!parse("|\n||\n| | |\n|-|").isEmpty)
    }

    @Test func pathologicalNestingFallsBackToPlainText() {
        let deep = String(repeating: ">", count: 10_000) + " x"
        #expect(parse(deep) == [.paragraph([plain(deep)])])
    }

    /// Compares growth, not an absolute budget, so a slow or loaded runner
    /// can't fail it: 4× the blocks takes ~4× as long when linear, ~16× when
    /// quadratic (the sibling-lookup bug this guards against). Each size takes
    /// the best of three runs, so one scheduler stall can't skew the ratio.
    @Test func manySiblingBlocksParseInLinearTime() {
        let clock = ContinuousClock()
        func timeParse(_ count: Int) -> Duration {
            let doc = String(repeating: "p\n\n", count: count)
            var blocks: [LeoMarkdownBlock] = []
            let runs = (0..<3).map { _ in clock.measure { blocks = parse(doc) } }
            #expect(blocks.count == count)
            return runs.min() ?? .zero
        }
        let small = timeParse(3_000)
        let large = timeParse(12_000)
        #expect(large < small * 8)
    }

    @Test func costCountsNestedBlocksAndTableCells() {
        let doc = LeoMarkdownDocument.parse("- a\n  > q\n\n| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
        // list, its paragraph, the quote, the quote's paragraph, and the table.
        #expect(doc.blockCount == 5)
        // 2 header cells + 2 rows of 2.
        #expect(doc.tableCellCount == 6)
    }
}
