import Foundation
import LeoKit
import Testing
import UIKit

@testable import Leo

@MainActor
struct ChatMarkdownTextTests {
    private let traits = UITraitCollection(preferredContentSizeCategory: .large)

    private func attributes(_ runs: [LeoMarkdownRun], style: ChatMarkdownText.Style = .body, traits: UITraitCollection? = nil) -> NSAttributedString {
        ChatMarkdownText.attributed(runs, style: style, traits: traits ?? self.traits)
    }

    @Test func allowedLinkCarriesLinkAttributeAndFilteredRunDoesNot() throws {
        let url = try #require(URL(string: "https://example.com"))
        let text = attributes([
            LeoMarkdownRun(text: "yes", link: url),
            LeoMarkdownRun(text: "no"),
        ])
        #expect(text.string == "yesno")
        #expect(text.attribute(.link, at: 0, effectiveRange: nil) as? URL == url)
        #expect(text.attribute(.link, at: 4, effectiveRange: nil) == nil)
    }

    @Test func strongAndEmphasisGiveBoldItalicFont() throws {
        let text = attributes([LeoMarkdownRun(text: "x", traits: [.strong, .emphasis])])
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    @Test func fontGrowsWithAccessibilitySizes() throws {
        let large = attributes([LeoMarkdownRun(text: "x")])
        let huge = attributes([LeoMarkdownRun(text: "x")], traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge))
        let small = try #require(large.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let big = try #require(huge.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(big.pointSize > small.pointSize)
    }
}
