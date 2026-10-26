import AppKit
import LeoKit

/// The browser pane's one toolbar row: back, forward and reload, the address
/// bar, new tab, then the control pill (**Agent driving** / **You have
/// control**) at the trailing end, with Give Back beside it while the user is
/// driving. Below `compactWidth` the pill shrinks to its icon so the address
/// bar keeps its room. Drawn from `LeoAgentBrowserPaneModel`; every click goes
/// back to it.
final class LeoAgentBrowserToolbar: NSView {
    static let rowHeight: CGFloat = 30
    /// Narrower than this, the pill drops its words.
    static let compactWidth: CGFloat = 460
    private static let minimumURLWidth: CGFloat = 96

    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    var onReload: () -> Void = {}
    var onNewTab: () -> Void = {}
    var onSubmitURL: (String) -> Void = { _ in }
    var onPill: () -> Void = {}
    var onGiveBack: () -> Void = {}

    let backButton = LeoAgentBrowserToolbar.symbolButton("chevron.backward", label: "Back")
    let forwardButton = LeoAgentBrowserToolbar.symbolButton("chevron.forward", label: "Forward")
    let reloadButton = LeoAgentBrowserToolbar.symbolButton("arrow.clockwise", label: "Reload")
    let newTabButton = LeoAgentBrowserToolbar.symbolButton("plus", label: "New Tab")
    let urlField = NSTextField()
    let pill = LeoControlPill()
    let giveBackButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func update(_ model: LeoAgentBrowserPaneModel) {
        backButton.isEnabled = model.canGoBack
        forwardButton.isEnabled = model.canGoForward
        let reloadLabel = model.isLoading ? "Loading" : "Reload"
        reloadButton.image = NSImage(systemSymbolName: model.isLoading ? "ellipsis" : "arrow.clockwise", accessibilityDescription: reloadLabel)
        reloadButton.toolTip = reloadLabel
        reloadButton.isEnabled = !model.isLoading
        newTabButton.isEnabled = model.tabItems.count < LeoBrowserLimits.maximumTabs
        // Leaves the address alone while it's being edited.
        if urlField.currentEditor() == nil { urlField.stringValue = model.urlText }
        urlField.toolTip = model.urlError
        urlField.textColor = model.urlError == nil ? .labelColor : .systemRed
        pill.show(model.pill)
        giveBackButton.isHidden = !model.pill.canGiveBack
    }

    override func layout() {
        super.layout()
        pill.isCompact = bounds.width < Self.compactWidth
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    private static func symbolButton(_ symbol: String, label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.refusesFirstResponder = true
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func build() {
        wantsLayer = true
        setAccessibilityElement(false)
        wire(backButton, #selector(back(_:)))
        wire(forwardButton, #selector(forward(_:)))
        wire(reloadButton, #selector(reload(_:)))
        wire(newTabButton, #selector(newTab(_:)))

        urlField.placeholderString = "Search or enter website address"
        urlField.bezelStyle = .roundedBezel
        urlField.controlSize = .small
        urlField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        urlField.lineBreakMode = .byTruncatingTail
        urlField.cell?.isScrollable = true
        urlField.target = self
        urlField.action = #selector(submit(_:))
        urlField.setAccessibilityLabel("Address")
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumURLWidth).isActive = true

        giveBackButton.isBordered = false
        giveBackButton.attributedTitle = NSAttributedString(string: "Give Back", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .medium),
            .foregroundColor: NSColor.controlAccentColor,
        ])
        giveBackButton.toolTip = "Let the agent drive the browser again"
        giveBackButton.refusesFirstResponder = true
        giveBackButton.target = self
        giveBackButton.action = #selector(giveBack(_:))
        giveBackButton.isHidden = true
        giveBackButton.setContentHuggingPriority(.required, for: .horizontal)
        giveBackButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.onClick = { [weak self] in self?.onPill() }

        let row = NSStackView(views: [backButton, forwardButton, reloadButton, urlField, newTabButton, pill, giveBackButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.setCustomSpacing(8, after: newTabButton)
        row.setCustomSpacing(4, after: pill)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
        ])
    }

    private func wire(_ button: NSButton, _ action: Selector) {
        button.target = self
        button.action = action
    }

    @objc private func back(_ sender: Any?) { onBack() }
    @objc private func forward(_ sender: Any?) { onForward() }
    @objc private func reload(_ sender: Any?) { onReload() }
    @objc private func newTab(_ sender: Any?) { onNewTab() }
    @objc private func giveBack(_ sender: Any?) { onGiveBack() }
    @objc private func submit(_ sender: Any?) { onSubmitURL(urlField.stringValue) }
}

/// The control pill: a compact capsule saying who is driving. Neutral while
/// the agent drives (clicking it takes control), accented while the user does.
final class LeoControlPill: NSButton {
    var onClick: () -> Void = {}
    /// Shows the icon alone; the words stay in the tooltip and for VoiceOver.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            refreshTitle()
        }
    }
    private var current: LeoAgentBrowserPaneModel.Pill?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageLeading
        imageHugsTitle = true
        wantsLayer = true
        refusesFirstResponder = true
        target = self
        action = #selector(clicked(_:))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func show(_ pill: LeoAgentBrowserPaneModel.Pill) {
        current = pill
        image = NSImage(systemSymbolName: pill.symbol, accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
        toolTip = pill.isAgentDriving ? "The agent is driving. Click to take control." : pill.canGiveBack ? "You are driving." : "The agent is waiting for you."
        setAccessibilityLabel(pill.title)
        refreshTitle()
    }

    private func refreshTitle() {
        guard let current else { return }
        title = isCompact ? "" : " \(current.title)"
        imagePosition = isCompact ? .imageOnly : .imageLeading
        needsDisplay = true
        invalidateIntrinsicContentSize()
        updateLayer()
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + (isCompact ? 12 : 14), height: 18)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isAgentDriving = current?.isAgentDriving ?? true
        layer?.cornerRadius = 9
        layer?.backgroundColor = (isAgentDriving ? NSColor.labelColor.withAlphaComponent(0.08) : NSColor.controlAccentColor.withAlphaComponent(0.2)).cgColor
        let ink: NSColor = isAgentDriving ? .secondaryLabelColor : .labelColor
        contentTintColor = isAgentDriving ? .secondaryLabelColor : .controlAccentColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .medium),
            .foregroundColor: ink,
        ])
    }

    @objc private func clicked(_ sender: Any?) { onClick() }
}
