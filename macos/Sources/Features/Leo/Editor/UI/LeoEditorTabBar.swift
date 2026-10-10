import AppKit

/// The editor pane's tab strip (B-273): one button per open file, under the
/// pane's header, shown once the pane has two or more tabs. Each tab shows
/// its file's name (sanitized, as the header shows it), a dot while it has
/// unsaved edits, and a close button on hover or while selected. It
/// scrolls sideways when the tabs don't fit. Inside the pane, not a window
/// tab bar (P6).
final class LeoEditorTabBar: NSView {
    struct Item: Equatable {
        let title: String
        let toolTip: String
        let isDirty: Bool
        let isSelected: Bool
    }

    static let height: CGFloat = 26

    var onSelect: (Int) -> Void = { _ in }
    var onClose: (Int) -> Void = { _ in }

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private(set) var items: [Item] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    var buttons: [LeoEditorTabButton] { stack.arrangedSubviews.compactMap { $0 as? LeoEditorTabButton } }

    func update(_ items: [Item]) {
        guard items != self.items else { return }
        self.items = items
        let buttons = buttons
        for (index, item) in items.enumerated() {
            let button = buttons.indices.contains(index) ? buttons[index] : addButton()
            button.index = index
            button.item = item
        }
        buttons.dropFirst(items.count).forEach { $0.removeFromSuperview() }
        if let selected = items.firstIndex(where: \.isSelected), self.buttons.indices.contains(selected) {
            let button = self.buttons[selected]
            layoutSubtreeIfNeeded()
            button.scrollToVisible(button.bounds)
        }
    }

    private func addButton() -> LeoEditorTabButton {
        let button = LeoEditorTabButton()
        button.onSelect = { [weak self, weak button] in
            guard let self, let button else { return }
            onSelect(button.index)
        }
        button.onClose = { [weak self, weak button] in
            guard let self, let button else { return }
            onClose(button.index)
        }
        stack.addArrangedSubview(button)
        return button
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    private func build() {
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Editor tabs")

        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = LeoFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: border.topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }
}

/// One tab in the strip: a click selects it, its button closes it.
final class LeoEditorTabButton: NSView {
    static let maximumWidth: CGFloat = 180

    var index = 0
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    var item = LeoEditorTabBar.Item(title: "", toolTip: "", isDirty: false, isSelected: false) {
        didSet { refresh() }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    let closeButton = NSButton()
    private var isHovered = false {
        didSet { refresh() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = item.isSelected ? NSColor.textBackgroundColor.cgColor : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onSelect()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func accessibilityPerformPress() -> Bool {
        onSelect()
        return true
    }

    private func refresh() {
        titleLabel.stringValue = item.title
        titleLabel.textColor = item.isSelected ? .labelColor : .secondaryLabelColor
        toolTip = item.toolTip
        // A dot while edited, the close button on hover or while selected.
        let showsDot = item.isDirty && !isHovered
        closeButton.image = NSImage(
            systemSymbolName: showsDot ? "circle.fill" : "xmark",
            accessibilityDescription: showsDot ? "Edited — Close Tab" : "Close Tab"
        )
        closeButton.symbolConfiguration = .init(pointSize: showsDot ? 7 : NSFont.smallSystemFontSize - 1, weight: .semibold)
        closeButton.alphaValue = item.isSelected || isHovered || item.isDirty ? 1 : 0
        setAccessibilityLabel(item.isDirty ? "\(item.title), edited" : item.title)
        setAccessibilityValue(item.isSelected)
        needsDisplay = true
    }

    private func build() {
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)

        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityElement(false)

        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close Tab"
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.refusesFirstResponder = true
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [titleLabel, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: LeoEditorTabBar.height - 1),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumWidth),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
        ])
        refresh()
    }

    @objc private func close(_ sender: Any?) {
        onClose()
    }
}

/// A document view laid out top-down.
private final class LeoFlippedView: NSView {
    override var isFlipped: Bool { true }
}
