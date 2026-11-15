import AppKit
import Quartz

/// A PDF or Office/iWork document through Quick Look (B-278). `close()`
/// ends the preview before its folder is deleted; nothing else closes it
/// (not its window, since tabs move the view between hosts).
final class LeoQuickLookPreviewView: NSView {
    private let preview: QLPreviewView

    init(url: URL, name: String) {
        preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        super.init(frame: .zero)
        preview.shouldCloseWithWindow = false
        preview.autostarts = true
        preview.previewItem = url as NSURL
        preview.setAccessibilityLabel(name)
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    private(set) var isClosed = false

    func close() {
        guard !isClosed else { return }
        isClosed = true
        preview.close()
    }
}
