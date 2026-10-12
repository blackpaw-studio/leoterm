import AppKit

/// Rendered Markdown (B-278): a read-only, selectable TextKit 1 text view
/// (`NSTextTable` needs TextKit 1). A link click opens only a web or mail
/// link, in the default browser or mail app; nothing else is followed.
final class LeoRenderedTextView: NSTextView, NSTextViewDelegate {
    static func make() -> (NSScrollView, LeoRenderedTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        // An explicit TextKit 1 stack: a plain NSTextView may be TextKit 2.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = LeoRenderedTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize), textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.delegate = textView
        textView.setAccessibilityLabel("Rendered Markdown")
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    func show(_ rendered: NSAttributedString) {
        textStorage?.setAttributedString(rendered)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, LeoMarkdownRenderer.isAllowedLink(url) { NSWorkspace.shared.open(url) }
        return true
    }
}
