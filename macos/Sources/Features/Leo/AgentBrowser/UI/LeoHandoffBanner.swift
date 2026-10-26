import AppKit

/// The banner under the browser toolbar while the agent waits on a handoff
/// (`browser_handoff`): its message and Decline / Done. Inline, like the
/// editor's banner, so the page stays visible while the user helps.
final class LeoHandoffBanner: NSView {
    var onDone: () -> Void = {}
    var onDecline: () -> Void = {}

    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private(set) var handoff: LeoAgentBrowserPaneModel.Handoff?
    let doneButton = LeoHandoffDoneButton()
    let declineButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

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
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(declineButton, title: "Decline", action: #selector(decline(_:)))
        configure(doneButton, title: "Done", action: #selector(done(_:)))
        doneButton.styleAsProminent()
        doneButton.toolTip = "Give the browser back to the agent"
        declineButton.toolTip = "Tell the agent you won't do this"

        let buttons = NSStackView(views: [declineButton, doneButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, label, buttons])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
        guard !isHidden, let window, window.isKeyWindow,
              event.type == .keyDown, event.keyCode == Self.returnKeyCode,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              isFocusInPane(window.firstResponder) else { return super.performKeyEquivalent(with: event) }
        performClick(nil)
        return true
    }

    private static let returnKeyCode: UInt16 = 36
}
