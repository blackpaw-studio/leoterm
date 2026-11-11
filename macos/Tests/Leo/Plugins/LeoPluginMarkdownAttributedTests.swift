import AppKit
import Foundation
import Testing

import LeoKit
@testable import Ghostty

@MainActor
struct LeoPluginMarkdownAttributedTests {
    private func render(_ md: String) -> NSAttributedString {
        LeoPluginMarkdownRenderer.attributedString(for: LeoPluginMarkdown.parse(md))
    }

    private func font(in s: NSAttributedString, at needle: String) -> NSFont? {
        let range = (s.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }

    private func attr(_ key: NSAttributedString.Key, in s: NSAttributedString, at needle: String) -> Any? {
        let range = (s.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return s.attribute(key, at: range.location, effectiveRange: nil)
    }

    @Test func headingsAreBoldAndShrinkWithLevel() throws {
        let s = render("# Big\n\n### Small\n\nbody")
        let big = try #require(font(in: s, at: "Big"))
        let small = try #require(font(in: s, at: "Small"))
        let body = try #require(font(in: s, at: "body"))
        #expect(big.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(big.pointSize > small.pointSize)
        #expect(small.pointSize > body.pointSize)
    }

    @Test func emphasisAndStrongUseItalicAndBoldTraits() throws {
        let s = render("a *soft* and **loud** word")
        let soft = try #require(font(in: s, at: "soft"))
        let loud = try #require(font(in: s, at: "loud"))
        #expect(soft.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(loud.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(try #require(font(in: s, at: "word")).fontDescriptor.symbolicTraits.isDisjoint(with: [.bold, .italic]))
    }

    @Test func inlineAndBlockCodeAreMonospacedWithABackground() throws {
        let s = render("run `ls -l` now\n\n```\nlet x = 1\n```")
        for needle in ["ls -l", "let x = 1"] {
            let f = try #require(font(in: s, at: needle))
            #expect(f.isFixedPitch, "\(needle) should be monospaced")
            #expect(attr(.backgroundColor, in: s, at: needle) != nil)
        }
        #expect(attr(.backgroundColor, in: s, at: "run") == nil)
    }

    @Test func httpsLinksCarryTheirURLAndOthersStayPlain() throws {
        let s = render("see [docs](https://example.com/docs) and [bad](javascript:alert(1))")
        #expect(attr(.link, in: s, at: "docs") as? URL == URL(string: "https://example.com/docs"))
        #expect(attr(.link, in: s, at: "bad") == nil)
    }

    @Test func listsGetBulletsOrNumbersAndHangingIndents() throws {
        let s = render("- one\n- two\n\n1. first\n2. second")
        #expect(s.string.contains("•\tone"))
        #expect(s.string.contains("•\ttwo"))
        #expect(s.string.contains("1.\tfirst"))
        #expect(s.string.contains("2.\tsecond"))
        let style = try #require(attr(.paragraphStyle, in: s, at: "one") as? NSParagraphStyle)
        #expect(style.headIndent > style.firstLineHeadIndent)
    }

    @Test func textColorIsADynamicSystemColorSoDarkModeWorks() throws {
        let s = render("plain")
        let color = try #require(attr(.foregroundColor, in: s, at: "plain") as? NSColor)
        #expect(color == NSColor.labelColor)
    }

    @Test func emptyMarkdownRendersEmptyString() {
        #expect(render("").length == 0)
    }
}
