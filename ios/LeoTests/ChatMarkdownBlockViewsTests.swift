import LeoKit
import Testing
import UIKit

@testable import Leo

@MainActor
struct ChatMarkdownBlockViewsTests {
    private static let width: CGFloat = 390

    private func laidOut(_ markdown: String) -> UIView {
        let stack = UIStackView(arrangedSubviews: LeoMarkdownDocument.parse(markdown).blocks.map {
            ChatMarkdownBlockViews.view(for: $0, traits: UITraitCollection(preferredContentSizeCategory: .large))
        })
        stack.axis = .vertical
        stack.frame = CGRect(x: 0, y: 0, width: Self.width, height: 1_000)
        stack.setNeedsLayout()
        stack.layoutIfNeeded()
        return stack
    }

    private func descendants<T: UIView>(of view: UIView, as type: T.Type = T.self) -> [T] {
        view.subviews.flatMap { sub -> [T] in
            let nested = descendants(of: sub, as: type)
            return (sub as? T).map { [$0] + nested } ?? nested
        }
    }

    private func scrollView(_ id: String, in view: UIView) -> UIScrollView? {
        descendants(of: view, as: UIScrollView.self).first { $0.accessibilityIdentifier == id }
    }

    private func table(columns: Int) -> String {
        let header = "|" + (0..<columns).map { " Column \($0) heading " }.joined(separator: "|") + "|"
        let divider = "|" + String(repeating: "---|", count: columns)
        let row = "|" + (0..<columns).map { " value number \($0) " }.joined(separator: "|") + "|"
        return [header, divider, row].joined(separator: "\n")
    }

    @Test func wideTableScrollsHorizontally() throws {
        let view = laidOut(table(columns: 8))
        let scroll = try #require(scrollView("markdown.table", in: view))
        #expect(scroll.contentSize.width > scroll.bounds.width)
    }

    @Test func narrowTableFitsTheWidth() throws {
        let view = laidOut("| A | B |\n|---|---|\n| 1 | 2 |")
        let scroll = try #require(scrollView("markdown.table", in: view))
        #expect(scroll.contentSize.width <= scroll.bounds.width)
    }

    @Test func nestedListUsesBulletThenHollowBullet() {
        let view = laidOut("- a\n  - b")
        let markers = descendants(of: view, as: UILabel.self).compactMap(\.text)
        #expect(markers == ["•", "◦"])
    }

    @Test func codeBlockDoesNotWrap() throws {
        let view = laidOut("```\n" + String(repeating: "x", count: 200) + "\n```")
        let scroll = try #require(scrollView("markdown.code", in: view))
        #expect(scroll.contentSize.width > scroll.bounds.width)
    }
}
