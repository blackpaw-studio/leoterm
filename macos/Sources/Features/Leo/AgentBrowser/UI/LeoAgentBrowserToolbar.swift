import AppKit
import LeoKit

/// The browser pane's header: back, forward and reload, the address bar, new
/// tab and close; under it, the control row with the pill (**Agent driving** /
/// **You have control**) and Give back. Two rows so the address bar keeps its
/// room at the pane's minimum width. Drawn from `LeoAgentBrowserPaneModel`;
/// every click goes back to it.
final class LeoAgentBrowserToolbar: NSView {
    static let rowHeight: CGFloat = 30
    static let controlRowHeight: CGFloat = 28

    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    var onReload: () -> Void = {}
    var onNewTab: () -> Void = {}
    var onClose: () -> Void = {}
    var onSubmitURL: (String) -> Void = { _ in }
    var onPill: () -> Void = {}
    var onGiveBack: () -> Void = {}

    let backButton = LeoAgentBrowserToolbar.symbolButton("chevron.backward", label: "Back")
    let forwardButton = LeoAgentBrowserToolbar.symbolButton("chevron.forward", label: "Forward")
    let reloadButton = LeoAgentBrowserToolbar.symbolButton("arrow.clockwise", label: "Reload")
    let newTabButton = LeoAgentBrowserToolbar.symbolButton("plus", label: "New Tab")
    let closeButton = LeoAgentBrowserToolbar.symbolButton("xmark", label: "Close Browser")
    let urlField = NSTextField()
    let pill = LeoControlPill()
    let giveBackButton = NSButton()
    private let controlRow = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    /// The header row, for `LeoTitlebarInsets.insetHeader`.
    var headerRow: NSView { urlField.superview ?? self }

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

    private static func symbolButton(_ symbol: String, label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.refusesFirstResponder = true
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    private func build() {
        wantsLayer = true
        setAccessibilityElement(false)
        wire(backButton, #selector(back(_:)))
        wire(forwardButton, #selector(forward(_:)))
        wire(reloadButton, #selector(reload(_:)))
        wire(newTabButton, #selector(newTab(_:)))
        wire(closeButton, #selector(close(_:)))

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

        let header = NSStackView(views: [backButton, forwardButton, reloadButton, urlField, newTabButton, closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 2
        header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        giveBackButton.title = "Give Back"
        giveBackButton.controlSize = .small
        giveBackButton.bezelStyle = .push
        giveBackButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        giveBackButton.toolTip = "Let the agent drive the browser again"
        giveBackButton.refusesFirstResponder = true
        giveBackButton.target = self
        giveBackButton.action = #selector(giveBack(_:))
        giveBackButton.isHidden = true
        pill.onClick = { [weak self] in self?.onPill() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlRow.setViews([pill, giveBackButton, spacer], in: .leading)
        controlRow.orientation = .horizontal
        controlRow.alignment = .centerY
        controlRow.spacing = 8
        controlRow.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)

        let rows = NSStackView(views: [header, controlRow])
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            controlRow.heightAnchor.constraint(equalToConstant: Self.controlRowHeight),
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
    @objc private func close(_ sender: Any?) { onClose() }
    @objc private func giveBack(_ sender: Any?) { onGiveBack() }
    @objc private func submit(_ sender: Any?) { onSubmitURL(urlField.stringValue) }
}

/// The control pill: a capsule saying who is driving. Clicking it takes
/// control when the agent is driving.
final class LeoControlPill: NSButton {
    var onClick: () -> Void = {}
    private var isAgentDriving = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageLeading
        imageHugsTitle = true
        font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        wantsLayer = true
        refusesFirstResponder = true
        target = self
        action = #selector(clicked(_:))
        setContentHuggingPriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func show(_ pill: LeoAgentBrowserPaneModel.Pill) {
        isAgentDriving = pill.isAgentDriving
        title = " \(pill.title)"
        image = NSImage(systemSymbolName: pill.symbol, accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
        toolTip = isAgentDriving ? "The agent is driving. Click to take control." : pill.canGiveBack ? "You are driving." : "The agent is waiting for you."
        setAccessibilityLabel(pill.title)
        needsDisplay = true
        needsLayout = true
        invalidateIntrinsicContentSize()
        updateLayer()
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 14, height: 20)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let tint = isAgentDriving ? NSColor.controlAccentColor : NSColor.systemGreen
        layer?.cornerRadius = 10
        layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        contentTintColor = isAgentDriving ? .controlAccentColor : .systemGreen
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    @objc private func clicked(_ sender: Any?) { onClick() }
}
