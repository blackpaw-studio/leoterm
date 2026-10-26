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
    let doneButton = NSButton()
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
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(declineButton, title: "Decline", action: #selector(decline(_:)))
        configure(doneButton, title: "Done", action: #selector(done(_:)))
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
        // A stray Return in the page must not answer for the user.
        button.refusesFirstResponder = true
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
