import AppKit

/// The banner under the browser toolbar while the agent waits on a handoff
/// (`browser_handoff`): its message and Decline / Done. Inline, like the
/// editor's banner, so the page stays visible while the user helps.
final class LeoHandoffBanner: NSView {
    var onDone: () -> Void = {}
    var onDecline: () -> Void = {}

    /// At this width and above the buttons sit beside the message; below it
    /// they go under it, so the message gets the whole width to wrap in.
    static let wideWidth: CGFloat = 640
    private static let insets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
    private static let spacing: CGFloat = 8
    private static let iconWidth: CGFloat = 14

    private let icon = NSImageView()
    private let textRow = NSStackView()
    private let content = NSStackView()
    private let buttons = NSStackView()
    private var textFillsWidth: NSLayoutConstraint?
    private var isWide: Bool?
    private let label = NSTextField(wrappingLabelWithString: "")
    private(set) var handoff: LeoAgentBrowserPaneModel.Handoff?
    let doneButton = LeoHandoffDoneButton()
    let declineButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    /// The full message, for the tooltip.
    var toolTipForMessage: String? { label.toolTip }

    func show(_ handoff: LeoAgentBrowserPaneModel.Handoff?) {
        guard handoff != self.handoff else { return }
        self.handoff = handoff
        isHidden = handoff == nil
        guard let handoff else { return }
        label.stringValue = handoff.message
        label.toolTip = handoff.message
        setAccessibilityLabel("Agent needs you: \(handoff.message)")
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func build() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true

        icon.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        // Long messages end in an ellipsis rather than pushing the buttons off.
        label.maximumNumberOfLines = 3
        // Wraps; only the last of the three lines is cut short.
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(declineButton, title: "Decline", action: #selector(decline(_:)))
        configure(doneButton, title: "Done", action: #selector(done(_:)))
        doneButton.styleAsProminent()
        doneButton.toolTip = "Give the browser back to the agent"
        declineButton.toolTip = "Tell the agent you won't do this"

        buttons.setViews([declineButton, doneButton], in: .leading)
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        textRow.setViews([icon, label], in: .leading)
        textRow.orientation = .horizontal
        textRow.alignment = .top
        textRow.spacing = Self.spacing

        content.setViews([textRow, buttons], in: .leading)
        content.spacing = Self.spacing
        content.edgeInsets = Self.insets
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let fill = textRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -(Self.insets.left + Self.insets.right))
        textFillsWidth = fill
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        arrange(wide: true)
    }

    /// Wide: message and buttons on one row. Narrow: the buttons, trailing,
    /// under the message.
    private func arrange(wide: Bool) {
        guard wide != isWide else { return }
        isWide = wide
        content.orientation = wide ? .horizontal : .vertical
        content.alignment = wide ? .centerY : .trailing
        textFillsWidth?.isActive = !wide
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// A wrapping label only knows its height once told its width.
    override func layout() {
        super.layout()
        arrange(wide: bounds.width >= Self.wideWidth)
        let used = Self.insets.left + Self.insets.right + Self.iconWidth + Self.spacing
        let beside = isWide == true ? buttons.fittingSize.width + Self.spacing : 0
        let width = max(bounds.width - used - beside, 0)
        guard abs(label.preferredMaxLayoutWidth - width) > 0.5 else { return }
        label.preferredMaxLayoutWidth = width
        label.invalidateIntrinsicContentSize()
        super.layout()
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.target = self
        button.action = action
        button.controlSize = .small
        button.bezelStyle = .push
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    }

    /// Drawn rather than layer-backed so the tint follows the appearance;
    /// within the bounds only (views don't clip on macOS 14+).
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        dirtyRect.intersection(bounds).fill()
    }

    @objc private func done(_ sender: Any?) { onDone() }
    @objc private func decline(_ sender: Any?) { onDecline() }
}

/// Done, the banner's prominent button: Return presses it, but only while
/// focus is in the pane's own controls -- never while the user types in the
/// page or the address bar, where Return belongs to them.
final class LeoHandoffDoneButton: NSButton {
    /// Accent-filled with white text: drawn here rather than left to the
    /// bezel so it reads as the primary answer in either appearance.
    func styleAsProminent() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        let title = attributedTitle.string.isEmpty ? self.title : attributedTitle.string
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isHighlighted ? NSColor.controlAccentColor.blended(withFraction: 0.25, of: .black) ?? .controlAccentColor : .controlAccentColor).cgColor
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 16, height: 20)
    }

    /// Whether `responder` is somewhere Return should answer the banner.
    var isFocusInPane: (NSResponder?) -> Bool = { _ in false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, let window, window.isKeyWindow,
              event.type == .keyDown, event.keyCode == Self.returnKeyCode,
              event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask),
              isFocusInPane(window.firstResponder) else { return super.performKeyEquivalent(with: event) }
        performClick(nil)
        return true
    }

    private static let returnKeyCode: UInt16 = 36
}
