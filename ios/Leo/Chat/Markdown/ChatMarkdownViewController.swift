import LeoKit
import UIKit

/// Native viewer for a Markdown attachment: Rendered / Raw toggle in the
/// navigation bar, Share for Open in / Save to Files. No web view.
final class ChatMarkdownViewController: UIViewController {
    private let text: String
    private let fileURL: URL
    private let displayTitle: String
    private var document = LeoMarkdownDocument(blocks: [])

    private let modeControl = UISegmentedControl(items: [String(localized: "Rendered"), String(localized: "Raw")])
    private let renderedScroll = UIScrollView()
    private let renderedContent = UIView()
    private let rawText = UITextView()
    private var renderedStack: UIView?

    init(text: String, fileURL: URL, title: String) {
        self.text = text
        self.fileURL = fileURL
        displayTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Parsed synchronously, once. Accepted: chat attachments are small.
        document = LeoMarkdownDocument.parse(text)
        configureNavigation()
        configureRendered()
        configureRaw()
        rebuildRendered()
        showMode(0)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.rebuildRendered()
        }
    }

    // MARK: Navigation

    private func configureNavigation() {
        navigationItem.title = displayTitle
        modeControl.selectedSegmentIndex = 0
        modeControl.accessibilityIdentifier = "markdown.mode"
        modeControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            showMode(modeControl.selectedSegmentIndex)
        }, for: .valueChanged)
        navigationItem.titleView = modeControl
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let share = UIBarButtonItem(systemItem: .action)
        share.accessibilityIdentifier = "markdown.share"
        share.primaryAction = UIAction { [weak self, weak share] _ in
            guard let self else { return }
            let sheet = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            sheet.popoverPresentationController?.barButtonItem = share
            present(sheet, animated: true)
        }
        navigationItem.rightBarButtonItem = share
    }

    private func showMode(_ index: Int) {
        renderedScroll.isHidden = index != 0
        rawText.isHidden = index == 0
    }

    // MARK: Rendered

    private func configureRendered() {
        renderedScroll.accessibilityIdentifier = "markdown.rendered"
        renderedScroll.translatesAutoresizingMaskIntoConstraints = false
        renderedContent.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(renderedScroll)
        renderedScroll.addSubview(renderedContent)
        let content = renderedScroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            renderedScroll.topAnchor.constraint(equalTo: view.topAnchor),
            renderedScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            renderedScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderedScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            renderedContent.topAnchor.constraint(equalTo: content.topAnchor),
            renderedContent.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            renderedContent.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            renderedContent.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            renderedContent.widthAnchor.constraint(equalTo: renderedScroll.frameLayoutGuide.widthAnchor),
        ])
    }

    private func rebuildRendered() {
        renderedStack?.removeFromSuperview()
        let stack = ChatMarkdownBlockViews.renderedView(for: document, source: text, traits: traitCollection)
        stack.translatesAutoresizingMaskIntoConstraints = false
        renderedContent.addSubview(stack)
        let readable = renderedContent.readableContentGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: renderedContent.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: renderedContent.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: readable.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: readable.trailingAnchor),
        ])
        renderedStack = stack
    }

    // MARK: Raw

    private func configureRaw() {
        rawText.accessibilityIdentifier = "markdown.raw"
        rawText.isEditable = false
        rawText.isSelectable = true
        rawText.dataDetectorTypes = []
        rawText.backgroundColor = .systemBackground
        rawText.textColor = .label
        rawText.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        rawText.adjustsFontForContentSizeCategory = true
        rawText.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        rawText.text = text
        rawText.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rawText)
        NSLayoutConstraint.activate([
            rawText.topAnchor.constraint(equalTo: view.topAnchor),
            rawText.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rawText.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rawText.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}
