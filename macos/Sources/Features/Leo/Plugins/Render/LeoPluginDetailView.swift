import AppKit
import LeoKit

/// Read-only rich text for a Detail node. Standalone it scrolls; embedded in
/// a stacked slot it sizes to its text and the slot scrolls instead.
final class LeoPluginDetailView: NSView {
    private final class AutoHeightTextView: NSTextView {
        var fitsContent = false
        override var intrinsicContentSize: NSSize {
            guard fitsContent, let layoutManager, let textContainer else { return super.intrinsicContentSize }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height + textContainerInset.height * 2))
        }

        override func layout() {
            super.layout()
            if fitsContent { invalidateIntrinsicContentSize() }
        }
    }

    private let textView = AutoHeightTextView()
    private let embedded: Bool

    init(detail: LeoPluginNode.Detail, embedded: Bool) {
        self.embedded = embedded
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: LeoPluginRenderStyle.gutter, height: 10)
        textView.isRichText = true
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.fitsContent = embedded
        textView.delegate = self

        if embedded {
            textView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textView)
            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: trailingAnchor),
                textView.topAnchor.constraint(equalTo: topAnchor),
                textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = textView
            scroll.translatesAutoresizingMaskIntoConstraints = false
            addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                scroll.topAnchor.constraint(equalTo: topAnchor),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        update(detail: detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(detail: LeoPluginNode.Detail) {
        textView.textStorage?.setAttributedString(
            LeoPluginMarkdownRenderer.attributedString(for: detail.blocks))
        textView.invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        embedded ? NSSize(width: NSView.noIntrinsicMetric, height: textView.intrinsicContentSize.height) : super.intrinsicContentSize
    }
}

extension LeoPluginDetailView: NSTextViewDelegate {
    /// Links open in the default browser and only when https; markdown already
    /// refuses other schemes, this is the second check at the click.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme?.lowercased() == "https" else { return true }
        NSWorkspace.shared.open(url)
        return true
    }
}
