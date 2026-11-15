import AppKit
import Testing

@testable import Ghostty

/// The pane's content row (B-278): a big Markdown render finishing late
/// never covers a newer one, and a preview's view never sizes the pane.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LeoEditorContentHostTests {
    /// Render `n` waits until `release(n)`, then renders its source as is.
    private final class Renders: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

        var startedCount: Int { lock.withLock { started } }

        func render(_ source: String) async -> LeoRenderedMarkdown {
            let index = lock.withLock {
                started += 1
                return started
            }
            await withCheckedContinuation { continuation in lock.withLock { waiting[index] = continuation } }
            return LeoRenderedMarkdown(NSAttributedString(string: source))
        }

        func release(_ index: Int) {
            lock.withLock { waiting.removeValue(forKey: index) }?.resume()
        }
    }

    private func makeHost(render: @escaping LeoEditorContentHostView.Render = LeoEditorContentHostView.render) -> LeoEditorContentHostView {
        let (scrollView, textView) = LeoEditorTextView.make()
        return LeoEditorContentHostView(textScrollView: scrollView, textView: textView, render: render, syncRenderLimit: 0)
    }

    @Test func aStaleRenderNeverCoversANewerOne() async throws {
        let renders = Renders()
        let host = makeHost(render: { await renders.render($0) })

        host.show(.markdown, source: { "old" }, name: "a.md", revealTitle: "Show in Finder")
        try await until { renders.startedCount == 1 }
        host.show(.markdown, source: { "new" }, name: "a.md", revealTitle: "Show in Finder", rerender: true)
        try await until { renders.startedCount == 2 }
        renders.release(2)
        try await until { await MainActor.run { host.renderedTextView.string == "new" } }
        renders.release(1)
        try await until { await MainActor.run { host.discardedRenders == 1 } }

        #expect(host.renderedTextView.string == "new")
    }

    @Test func previewViewsNeverSizeThePane() throws {
        let host = makeHost()
        let movie = URL(fileURLWithPath: "/tmp/none.mp4")

        host.show(.movie(movie), source: { "" }, name: "a.mp4", revealTitle: "Download")

        let view = try #require(host.subviews.first as? LeoMoviePreviewView)
        #expect(view.intrinsicContentSize == NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric))
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            #expect(view.contentCompressionResistancePriority(for: orientation) < .defaultLow)
            #expect(view.contentHuggingPriority(for: orientation) < .defaultLow)
        }
        #expect(host.fittingSize.width < LeoEditorPaneViewController.minimumWidth)
    }

    /// Only a failure behind a closed connection says to reopen; an SVG
    /// that won't draw points to its source instead.
    @Test func reopenAdviceOnlyForAClosedConnection() throws {
        let host = makeHost()
        host.show(.svg, source: { "<svg" }, name: "a.svg", revealTitle: "Show in Finder")
        let svg = try #require(host.subviews.first as? LeoUnavailablePreviewView)
        let svgLabel = try #require(svg.accessibilityLabel())
        #expect(svgLabel.contains("Show Raw (⌥⌘U)"))
        #expect(!svgLabel.contains(LeoUnavailablePreviewView.reopenHint))

        host.show(.unavailable(typeName: "MPEG-4 movie", message: "It didn’t answer.", canRetry: false), source: { "" }, name: "a.mp4", revealTitle: "Download")
        let closed = try #require(host.subviews.first as? LeoUnavailablePreviewView)
        #expect(closed.accessibilityLabel()?.contains(LeoUnavailablePreviewView.reopenHint) == true)

        host.show(.unavailable(typeName: "MPEG-4 movie", message: "Permission denied.", canRetry: true), source: { "" }, name: "a.mp4", revealTitle: "Download")
        let retry = try #require(host.subviews.first as? LeoUnavailablePreviewView)
        #expect(retry.accessibilityLabel()?.contains(LeoUnavailablePreviewView.reopenHint) == false)
    }

    @Test func clearingLetsGoOfAQuickLookPreview() throws {
        let host = makeHost()
        host.show(.quickLook(URL(fileURLWithPath: "/tmp/none.pdf")), source: { "" }, name: "a.pdf", revealTitle: "Download")
        let preview = try #require(host.subviews.first as? LeoQuickLookPreviewView)

        host.clear()

        #expect(preview.isClosed)
        #expect(host.content == .empty)
        #expect(!host.subviews.contains(preview))
    }
}
