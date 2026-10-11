import AppKit

/// The pane's content row (B-278): one view at a time -- the text view,
/// rendered Markdown, an image, a movie, a Quick Look preview, a loading
/// bar or Can't Preview -- swapped as the tab's `LeoEditorPaneContent`
/// changes. The text view and the rendered view live as long as the tab
/// (undo, scroll and selection survive a Raw/Rendered switch); the others
/// are made per file and let go of it (a movie's item, Quick Look) as they
/// leave, so its folder can be deleted right after.
final class LeoEditorContentHostView: NSView {
    /// Markdown longer than this (UTF-16 units) renders off the main actor.
    static let syncRenderLimit = 200_000

    let textScrollView: NSScrollView
    let textView: LeoEditorTextView
    let renderedScrollView: NSScrollView
    let renderedTextView: LeoRenderedTextView
    private(set) var content = LeoEditorPaneContent.text
    private var current: NSView
    private var renderGeneration = 0
    /// Can't Preview's buttons.
    var onUnavailableAction: (LeoUnavailablePreviewView.Action) -> Void = { _ in }
    /// The image's zoom changed.
    var onZoomChange: () -> Void = {}

    init(textScrollView: NSScrollView, textView: LeoEditorTextView) {
        self.textScrollView = textScrollView
        self.textView = textView
        (renderedScrollView, renderedTextView) = LeoRenderedTextView.make()
        current = textScrollView
        super.init(frame: .zero)
        embed(textScrollView)
    }

    required init?(coder: NSCoder) { nil }

    /// The image on show, for zooming.
    var imagePreview: LeoImagePreviewView? { current as? LeoImagePreviewView }

    /// What focusing the pane focuses.
    var focusTarget: NSView {
        switch current {
        case textScrollView: textView
        case renderedScrollView: renderedTextView
        default: current
        }
    }

    /// Shows `content`. `source` is the buffer (Markdown or SVG to draw);
    /// `rerender` redraws it even when the content is unchanged (it was
    /// edited, or reloaded). `name` labels it; `revealTitle` names Can't
    /// Preview's button.
    func show(_ content: LeoEditorPaneContent, source: () -> String, name: String, revealTitle: String, rerender: Bool = false) {
        guard content != self.content || (rerender && Self.drawsSource(content)) else { return }
        if case .loading(let fraction) = content, let loading = current as? LeoLoadingPreviewView {
            self.content = content
            loading.update(fraction: fraction)
            return
        }
        self.content = content
        swap(to: makeView(for: content, source: source, name: name, revealTitle: revealTitle))
    }

    private static func drawsSource(_ content: LeoEditorPaneContent) -> Bool {
        content == .markdown || content == .svg
    }

    private func makeView(for content: LeoEditorPaneContent, source: () -> String, name: String, revealTitle: String) -> NSView {
        switch content {
        case .text:
            return textScrollView
        case .markdown:
            render(source())
            return renderedScrollView
        case .svg:
            guard let image = LeoImageDecode.image(svg: source()) else {
                return unavailable(LeoUnavailablePreviewView.title(typeName: "SVG"), "This SVG couldn’t be drawn. Show Raw (⌥⌘U) to see its source.", revealTitle)
            }
            return imageView(image, name: name)
        case .loading(let fraction):
            return LeoLoadingPreviewView(fraction: fraction)
        case .image(let url):
            guard let image = LeoImageDecode.image(contentsOf: url) else {
                return unavailable(LeoUnavailablePreviewView.title(typeName: "This Image"), "The image couldn’t be decoded.", revealTitle)
            }
            return imageView(image, name: name)
        case .movie(let url):
            return LeoMoviePreviewView(url: url, name: name)
        case .quickLook(let url):
            return LeoQuickLookPreviewView(url: url, name: name)
        case let .unavailable(typeName, message):
            return unavailable(LeoUnavailablePreviewView.title(typeName: typeName), message, revealTitle)
        case .empty:
            return NSView()
        }
    }

    private func imageView(_ image: NSImage, name: String) -> LeoImagePreviewView {
        let view = LeoImagePreviewView(image: image, name: name)
        view.onZoomChange = { [weak self] in self?.onZoomChange() }
        return view
    }

    private func unavailable(_ title: String, _ message: String?, _ revealTitle: String) -> NSView {
        let view = LeoUnavailablePreviewView(title: title, message: message, revealTitle: revealTitle)
        view.onAction = { [weak self] action in self?.onUnavailableAction(action) }
        return view
    }

    /// Lets go of the old view's file before anything deletes it, and keeps
    /// focus in the row if it was there.
    private func swap(to next: NSView) {
        guard next !== current else { return }
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: current) == true
        (current as? LeoQuickLookPreviewView)?.close()
        (current as? LeoMoviePreviewView)?.stop()
        current.removeFromSuperview()
        current = next
        embed(next)
        if hadFocus { window?.makeFirstResponder(focusTarget) }
    }

    private func embed(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Small Markdown renders at once; big Markdown off the main actor,
    /// a newer render superseding it.
    private func render(_ source: String) {
        renderGeneration += 1
        let generation = renderGeneration
        let renderer = LeoMarkdownRenderer()
        guard source.utf16.count > Self.syncRenderLimit else { return renderedTextView.show(renderer.render(source)) }
        renderedTextView.show(NSAttributedString(string: "Rendering…", attributes: [
            .font: renderer.bodyFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        Task.detached(priority: .userInitiated) { [weak self] in
            let rendered = LeoRendered(renderer.render(source))
            await MainActor.run {
                guard let self, generation == self.renderGeneration else { return }
                self.renderedTextView.show(rendered.value)
            }
        }
    }
}

/// A finished render, handed back to the main actor (never mutated).
private struct LeoRendered: @unchecked Sendable {
    let value: NSAttributedString

    init(_ value: NSAttributedString) { self.value = value }
}
