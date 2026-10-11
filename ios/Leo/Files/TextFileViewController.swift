import ComposableArchitecture
import LeoFeatures
import UIKit
import UIKitNavigation

/// A surfaced text or Markdown file, scrolled to the agent's `line` with
/// that line (or the Markdown block holding it) highlighted. Text shows
/// line numbers; Markdown renders. Shares the whole file, fetching it first
/// when the preview holds only its start.
final class TextFileViewController: UIViewController {
    @UIBindable private var store: StoreOf<FilePreview>
    private let textView = UITextView(usingTextLayoutManager: false)
    private let highlightView = UIView()
    private let truncationLabel = UILabel()
    private let shareSpinner = UIActivityIndicatorView(style: .medium)
    private lazy var shareItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .action, primaryAction: UIAction { [weak self] _ in self?.store.send(.shareButtonTapped) })
        item.accessibilityIdentifier = "file.share"
        return item
    }()
    private var highlightRange: NSRange?
    private var hasScrolledToLine = false

    init(store: StoreOf<FilePreview>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = store.file.displayName
        navigationItem.subtitle = store.line.map { String(localized: "Line \($0)") }
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground


        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.dataDetectorTypes = []
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        textView.layoutManager.allowsNonContiguousLayout = true
        textView.accessibilityIdentifier = "file.text"
        textView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.backgroundColor = .systemYellow.withAlphaComponent(0.28)
        highlightView.layer.cornerRadius = 4
        highlightView.isUserInteractionEnabled = false
        highlightView.isHidden = true
        highlightView.accessibilityIdentifier = "file.highlight"
        textView.insertSubview(highlightView, at: 0)

        truncationLabel.font = .preferredFont(forTextStyle: .footnote)
        truncationLabel.textColor = .secondaryLabel
        truncationLabel.textAlignment = .center
        truncationLabel.numberOfLines = 0
        truncationLabel.backgroundColor = .secondarySystemBackground
        truncationLabel.translatesAutoresizingMaskIntoConstraints = false
        truncationLabel.isHidden = !store.isTruncated
        truncationLabel.text = String(localized: "Showing the first \(ByteCountFormatter.string(fromByteCount: FilePreviewKind.textPreviewCap, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file)). Share to see all of it.")

        let stack = UIStackView(arrangedSubviews: [truncationLabel, textView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            truncationLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])

        let rendered = store.kind == .markdown
            ? MarkdownRenderer.render(store.text ?? "", highlightLine: store.line)
            : PlainTextRenderer.render(store.text ?? "", highlightLine: store.line)
        textView.attributedText = rendered.text
        highlightRange = rendered.highlight

        present(isPresented: $store.isSharing) { [weak self] in
            let controller = UIActivityViewController(activityItems: [self?.store.shareURL as Any], applicationActivities: nil)
            controller.popoverPresentationController?.barButtonItem = self?.shareItem
            return controller
        }
        present(item: $store.scope(state: \.alert, action: \.alert)) { store in
            UIAlertController(store: store)
        }

        observe { [weak self] in
            guard let self else { return }
            // Fetching the whole file to share: a spinner where the button was.
            if store.isPreparingShare {
                shareSpinner.startAnimating()
                navigationItem.rightBarButtonItem = UIBarButtonItem(customView: shareSpinner)
            } else {
                navigationItem.rightBarButtonItem = shareItem
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionHighlight()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        positionHighlight()
    }

    /// A full-width bar behind the highlighted text; the first time, the
    /// text scrolls so it sits a third of the way down.
    private func positionHighlight() {
        guard let range = highlightRange, range.location != NSNotFound, NSMaxRange(range) <= textView.textStorage.length else { return }
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        let inset = textView.textContainerInset
        highlightView.frame = CGRect(x: 4, y: rect.minY + inset.top - 2, width: textView.bounds.width - 8, height: rect.height + 4)
        highlightView.isHidden = false
        guard !hasScrolledToLine, textView.bounds.height > 0 else { return }
        hasScrolledToLine = true
        let maxOffset = max(0, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
        let target = min(max(highlightView.frame.minY - textView.bounds.height / 3, -textView.adjustedContentInset.top), maxOffset)
        textView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }
}

/// Text with a line-number gutter (wrapped lines hang past it) and the
/// highlighted line's range.
enum PlainTextRenderer {
    static func render(_ text: String, highlightLine: Int?) -> (text: NSAttributedString, highlight: NSRange?) {
        let lines = text.components(separatedBy: "\n")
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let numberFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
        let digits = String(lines.count).count
        let gutter = CGFloat(digits + 2) * ("0" as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: gutter)]
        paragraph.headIndent = gutter
        paragraph.lineBreakMode = .byCharWrapping

        let result = NSMutableAttributedString()
        var highlight: NSRange?
        for (index, line) in lines.enumerated() {
            let number = index + 1
            let start = result.length
            result.append(NSAttributedString(string: String(number).leftPadded(to: digits) + "\t", attributes: [
                .font: numberFont, .foregroundColor: number == highlightLine ? UIColor.label : UIColor.tertiaryLabel, .paragraphStyle: paragraph,
            ]))
            result.append(NSAttributedString(string: line + (number < lines.count ? "\n" : ""), attributes: [
                .font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
            ]))
            if number == highlightLine { highlight = NSRange(location: start, length: result.length - start) }
        }
        return (result, highlight)
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        String(repeating: " ", count: max(0, width - count)) + self
    }
}
