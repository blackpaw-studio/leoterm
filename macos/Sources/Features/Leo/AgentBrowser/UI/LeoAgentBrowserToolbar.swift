import AppKit
import LeoKit

/// The browser pane's one toolbar row: back, forward and reload, the address
/// bar, new tab, then the control pill (**Agent driving** / **You have
/// control**), with Give Back beside it while the user is driving, and the
/// More menu (B-409) at the trailing end. Below `compactWidth` the pill shrinks to its icon so the address
/// bar keeps its room. Drawn from `LeoAgentBrowserPaneModel`; every click goes
/// back to it.
final class LeoAgentBrowserToolbar: NSView, NSTextFieldDelegate {
    static let rowHeight: CGFloat = 30
    /// Narrower than this, the pill drops its words.
    static let compactWidth: CGFloat = 460
    private static let minimumURLWidth: CGFloat = 96

    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    /// The tab's pages behind or ahead, for the Back and Forward lists.
    var history: (LeoBrowserHistoryDirection) -> [LeoBrowserHistoryEntry] = { _ in [] }
    var onHistory: (LeoBrowserHistoryEntry) -> Void = { _ in }
    var onReload: () -> Void = {}
    var onNewTab: () -> Void = {}
    var onSubmitURL: (String) -> Void = { _ in }
    var onPill: () -> Void = {}
    var onGiveBack: () -> Void = {}
    /// What More shows: Open in Default Browser, Copy URL and Clear Site Data,
    /// set by the pane.
    var moreMenu: NSMenu?
    /// Pops `menu` under `button`; tests stand in for the menu's tracking loop.
    var showMenu: (_ menu: NSMenu, _ button: NSView) -> Void = { menu, button in
        let below = button.isFlipped ? button.bounds.maxY + 4 : button.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: below), in: button)
    }

    let backButton = LeoAgentBrowserToolbar.historyButton("chevron.backward", label: "Back (⌘[)")
    let forwardButton = LeoAgentBrowserToolbar.historyButton("chevron.forward", label: "Forward (⌘])")
    let reloadButton = LeoAgentBrowserToolbar.symbolButton("arrow.clockwise", label: "Reload")
    let newTabButton = LeoAgentBrowserToolbar.symbolButton("plus", label: "New Tab")
    let urlField = NSTextField()
    let pill = LeoControlPill()
    let giveBackButton = NSButton()
    let moreButton = LeoAgentBrowserToolbar.symbolButton("ellipsis.circle", label: "More")

    /// The page's committed address, as the model last reported it.
    private var pageURLText = ""
    /// The user has typed in the address bar since it was focused: their text
    /// stays until they commit it or press Escape. Until then the bar follows
    /// the page, focused or not (B-419).
    private var hasUserEdits = false
    /// The tab the bar showed last: another tab is another page, so an edit
    /// doesn't follow the user there.
    private var shownTabID: Int?

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
        pageURLText = model.urlText
        let activeTabID = model.tabItems.first(where: \.isActive)?.id
        if activeTabID != shownTabID {
            shownTabID = activeTabID
            hasUserEdits = false
        }
        if !hasUserEdits { urlField.stringValue = pageURLText }
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
        styled(NSButton(), symbol: symbol, label: label, toolTip: label)
    }

    /// Back or Forward: its tooltip says the key and that holding lists history.
    private static func historyButton(_ symbol: String, label: String) -> LeoBrowserHistoryButton {
        let name = label.split(separator: " ").first.map(String.init) ?? label
        let button = LeoBrowserHistoryButton()
        _ = styled(button, symbol: symbol, label: name, toolTip: "\(label) — press and hold for history")
        return button
    }

    private static func styled(_ button: NSButton, symbol: String, label: String, toolTip: String) -> NSButton {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = toolTip
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
        backButton.history = { [weak self] in self?.history(.back) ?? [] }
        forwardButton.history = { [weak self] in self?.history(.forward) ?? [] }
        backButton.onSelect = { [weak self] in self?.onHistory($0) }
        forwardButton.onSelect = { [weak self] in self?.onHistory($0) }
        wire(reloadButton, #selector(reload(_:)))
        wire(newTabButton, #selector(newTab(_:)))
        wire(moreButton, #selector(more(_:)))

        urlField.placeholderString = "Search or enter website address"
        urlField.bezelStyle = .roundedBezel
        urlField.controlSize = .small
        urlField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        urlField.lineBreakMode = .byTruncatingTail
        urlField.cell?.isScrollable = true
        urlField.delegate = self
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

        let row = NSStackView(views: [backButton, forwardButton, reloadButton, urlField, newTabButton, pill, giveBackButton, moreButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.setCustomSpacing(8, after: newTabButton)
        row.setCustomSpacing(4, after: pill)
        row.setCustomSpacing(6, after: giveBackButton)
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
    @objc private func more(_ sender: Any?) {
        guard let moreMenu else { return }
        showMenu(moreMenu, moreButton)
    }
    /// The pane calls this once it accepts an address: the bar follows the page
    /// again even while it keeps focus. A rejected address isn't committed, so
    /// it stays to be fixed.
    func commitEdit() { hasUserEdits = false }

    @objc private func submit(_ sender: Any?) { onSubmitURL(urlField.stringValue) }

    func controlTextDidChange(_ notification: Notification) { hasUserEdits = true }

    /// Focus leaving the bar drops an uncommitted edit and shows the page's
    /// address again; Return doesn't, since it commits the text (the pane
    /// calls `commitEdit` if it's good) and a rejected address keeps it.
    func controlTextDidEndEditing(_ notification: Notification) {
        let movement = notification.userInfo?[NSText.movementUserInfoKey] as? Int
        guard movement != NSReturnTextMovement else { return }
        if hasUserEdits { urlField.stringValue = pageURLText }
        hasUserEdits = false
    }

    /// Escape drops the user's edit and shows the page's address again.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        hasUserEdits = false
        urlField.stringValue = pageURLText
        return true
    }
}

/// The control pill: a compact capsule saying who is driving. Neutral while
/// the agent drives (clicking it takes control), accented while the user does.
/// Not final: a test counts its layer updates.
class LeoControlPill: NSButton {
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

    /// Title and tint live here: setting them marks the button for display,
    /// so `updateLayer` must never do it.
    private func refreshTitle() {
        guard let current else { return }
        imagePosition = isCompact ? .imageOnly : .imageLeading
        contentTintColor = current.isAgentDriving ? .secondaryLabelColor : .controlAccentColor
        attributedTitle = NSAttributedString(string: isCompact ? "" : " \(current.title)", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .medium),
            .foregroundColor: current.isAgentDriving ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + (isCompact ? 12 : 14), height: 18)
    }

    override var wantsUpdateLayer: Bool { true }

    /// Only the capsule. AppKit calls this with the view's own appearance
    /// current, so the colours resolve for this window, not the app.
    override func updateLayer() {
        let isAgentDriving = current?.isAgentDriving ?? true
        layer?.cornerRadius = 9
        layer?.backgroundColor = (isAgentDriving ? NSColor.labelColor.withAlphaComponent(0.08) : NSColor.controlAccentColor.withAlphaComponent(0.2)).cgColor
    }

    @objc private func clicked(_ sender: Any?) { onClick() }
}
