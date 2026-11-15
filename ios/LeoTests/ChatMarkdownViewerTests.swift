import Testing
import UIKit

@testable import Leo

@MainActor
struct ChatMarkdownViewerTests {
    private static let source = "# Title\n\nSome *text*."

    private func makeViewer() -> ChatMarkdownViewController {
        let viewer = ChatMarkdownViewController(text: Self.source, fileURL: URL.temporaryDirectory.appending(path: "doc.md"), title: "doc.md")
        viewer.loadViewIfNeeded()
        viewer.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        viewer.view.layoutIfNeeded()
        return viewer
    }

    private func find(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }

    private func segmented(_ viewer: ChatMarkdownViewController) -> UISegmentedControl? {
        viewer.navigationItem.titleView as? UISegmentedControl
    }

    @Test func renderedShowsByDefaultAndRawIsHidden() throws {
        let viewer = makeViewer()
        #expect(try #require(segmented(viewer)).selectedSegmentIndex == 0)
        #expect(try #require(find("markdown.rendered", in: viewer.view)).isHidden == false)
        #expect(try #require(find("markdown.raw", in: viewer.view)).isHidden)
    }

    @Test func togglingToRawShowsSourceVerbatim() throws {
        let viewer = makeViewer()
        let control = try #require(segmented(viewer))
        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)
        let raw = try #require(find("markdown.raw", in: viewer.view) as? UITextView)
        #expect(raw.isHidden == false)
        #expect(raw.text == Self.source)
        #expect(try #require(find("markdown.rendered", in: viewer.view)).isHidden)
    }

    @Test func shareItemExists() {
        #expect(makeViewer().navigationItem.rightBarButtonItem != nil)
    }
}
