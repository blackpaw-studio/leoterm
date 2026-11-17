import AppKit

/// The line at the foot of the browser pane for the latest download
/// (B-404): its progress, where it was saved, or plainly why it failed.
/// A failure stays until dismissed; a saved file's line goes by itself
/// (the model decides). Never takes focus.
final class LeoBrowserDownloadStrip: NSView {
    var onDismiss: () -> Void = {}

    private static let insets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 6)
    private static let progressWidth: CGFloat = 80

    private let row = NSStackView()
    private let icon = NSImageView()
    let label = NSTextField(wrappingLabelWithString: "")
    let progressBar = NSProgressIndicator()
    let dismissButton = NSButton()
    private(set) var strip: LeoAgentBrowserPaneModel.DownloadStrip?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func show(_ strip: LeoAgentBrowserPaneModel.DownloadStrip?) {
        guard strip != self.strip else { return }
        let changedKind = strip?.kind != self.strip?.kind || strip?.id != self.strip?.id
        self.strip = strip
        isHidden = strip == nil
        guard let strip else { return }
        label.stringValue = strip.text
        label.toolTip = strip.text
        label.textColor = strip.kind == .failed ? .systemRed : .labelColor
        setAccessibilityLabel(strip.text)
        if changedKind { icon.image = Self.symbol(for: strip.kind) }
        icon.contentTintColor = strip.kind == .failed ? .systemRed : (strip.kind == .finished ? .systemGreen : .secondaryLabelColor)
        progressBar.isHidden = strip.kind != .downloading
        if let fraction = strip.progress {
            progressBar.isIndeterminate = false
            progressBar.doubleValue = fraction
        } else if strip.kind == .downloading {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
        }
    }

    private static func symbol(for kind: LeoAgentBrowserPaneModel.DownloadStrip.Kind) -> NSImage? {
        let name = switch kind {
        case .downloading, .saving: "arrow.down.circle"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func build() {
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        icon.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setAccessibilityElement(false)

        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        progressBar.widthAnchor.constraint(equalToConstant: Self.progressWidth).isActive = true
        progressBar.setAccessibilityElement(false)

        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismissButton.isBordered = false
        dismissButton.bezelStyle = .accessoryBarAction
        dismissButton.imagePosition = .imageOnly
        dismissButton.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .medium)
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.refusesFirstResponder = true
        dismissButton.toolTip = "Dismiss"
        dismissButton.target = self
        dismissButton.action = #selector(dismiss(_:))
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)

        row.setViews([icon, label, progressBar, dismissButton], in: .leading)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = Self.insets
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func accessibilityChildren() -> [Any]? { [dismissButton] }

    /// A wrapping label only knows its height once told its width.
    override func layout() {
        super.layout()
        let used = row.edgeInsets.left + row.edgeInsets.right + icon.fittingSize.width + dismissButton.fittingSize.width
            + (progressBar.isHidden ? 0 : Self.progressWidth + row.spacing) + 2 * row.spacing
        let width = max(bounds.width - used, 0)
        guard abs(label.preferredMaxLayoutWidth - width) > 0.5 else { return }
        label.preferredMaxLayoutWidth = width
        label.invalidateIntrinsicContentSize()
    }

    @objc private func dismiss(_ sender: Any?) {
        onDismiss()
    }
}
