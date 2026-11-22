import AppKit
import LeoKit

/// A `Group` (apiVersion 2) in a pane or palette body: an inset rounded
/// block with a header (symbol, title, accessory, ⋯ actions menu), an
/// optional subtitle, and its meters and accessories indented under the
/// title. Actions are in the ⋯ menu, the context menu and the ⌘↩ panel;
/// Return runs the first. Metrics follow `docs/designs/usage-plugin/design.md`.
final class LeoPluginGroupView: NSView {
    private enum Metrics {
        static let cornerRadius: CGFloat = 10
        static let verticalPadding: CGFloat = 10
        static let horizontalPadding: CGFloat = 12
        /// Half the 10 pt gap between stacked Groups, on each side.
        static let outerVerticalInset: CGFloat = 5
        static let symbolColumn: CGFloat = 16
        static let symbolGap: CGFloat = 6
        static var indent: CGFloat { symbolColumn + symbolGap }
        static let childSpacing: CGFloat = 8
        static let menuButtonSize: CGFloat = 20
        static let inlineButtonHeight: CGFloat = 20
    }

    private let emitter: LeoPluginActionEmitter
    private(set) var group: LeoPluginNode.Group
    private let background = NSView()
    private let content = NSStackView()
    private var panel: NSPopover?

    init(group: LeoPluginNode.Group, emitter: LeoPluginActionEmitter) {
        self.group = group
        self.emitter = emitter
        super.init(frame: .zero)
        background.wantsLayer = true
        background.layer?.cornerRadius = Metrics.cornerRadius
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Metrics.childSpacing
        content.edgeInsets = NSEdgeInsets(
            top: Metrics.verticalPadding, left: Metrics.horizontalPadding,
            bottom: Metrics.verticalPadding, right: Metrics.horizontalPadding)
        layoutBackground()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        update(group: group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutBackground() {
        [background, content].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        let gutter = LeoPluginRenderStyle.gutter
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            background.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.outerVerticalInset),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.outerVerticalInset),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    func update(group: LeoPluginNode.Group) {
        self.group = group
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        addFullWidth(headerRow())
        if let subtitle = group.subtitle, !subtitle.isEmpty {
            let label = LeoPluginRenderStyle.label(subtitle, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, lines: 2)
            label.setAccessibilityElement(false)
            addFullWidth(label, indent: Metrics.indent)
            content.setCustomSpacing(2, after: content.arrangedSubviews[0])
        }
        let meters = childViews()
        meters.forEach { addFullWidth($0, indent: Metrics.indent) }
        alignMeterLabels(meters.compactMap { $0 as? LeoPluginValueMeterView })
        if meters.isEmpty, let first = LeoPluginActionPresentation.entries(for: group.actions).first {
            content.addArrangedSubview(inlineButton(first))
        }
        applyAccessibility()
        applyBackground()
    }

    // MARK: Pieces

    private func headerRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.symbolGap
        let symbol = NSImageView(image: LeoPluginRenderStyle.symbol(group.sfSymbol, pointSize: 13) ?? NSImage())
        symbol.contentTintColor = .secondaryLabelColor
        symbol.setAccessibilityElement(false)
        symbol.widthAnchor.constraint(equalToConstant: Metrics.symbolColumn).isActive = true
        row.addArrangedSubview(symbol)
        let title = LeoPluginRenderStyle.label(group.title, font: .systemFont(ofSize: 13, weight: .semibold))
        title.toolTip = group.title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(title)
        if let accessory = group.accessory { row.addArrangedSubview(LeoPluginAccessoryView(accessory: accessory)) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)
        if !group.actions.isEmpty { row.addArrangedSubview(menuButton()) }
        return row
    }

    private func childViews() -> [NSView] {
        group.children.map { child -> NSView in
            switch child {
            case .meter(let meter): LeoPluginValueMeterView(meter: meter, style: .regular)
            case .accessory(let accessory): LeoPluginAccessoryView(accessory: accessory)
            }
        }
    }

    /// All meters in the Group share the widest label's width (capped by each
    /// meter), so their tracks line up.
    private func alignMeterLabels(_ meters: [LeoPluginValueMeterView]) {
        guard let first = meters.first else { return }
        for other in meters.dropFirst() {
            let equal = other.label.widthAnchor.constraint(equalTo: first.label.widthAnchor)
            equal.priority = .defaultHigh
            equal.isActive = true
        }
    }

    private func menuButton() -> NSButton {
        let button = NSButton(
            image: LeoPluginRenderStyle.symbol("ellipsis.circle", pointSize: 13) ?? NSImage(),
            target: self, action: #selector(showActionsMenu(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Actions"
        button.setAccessibilityElement(false)  // the same actions are custom actions on the Group
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metrics.menuButtonSize),
            button.heightAnchor.constraint(equalToConstant: Metrics.menuButtonSize),
        ])
        return button
    }

    private func inlineButton(_ entry: LeoPluginActionEntry) -> NSView {
        let button = NSButton(title: entry.title, target: self, action: #selector(inlineChosen(_:)))
        button.image = LeoPluginRenderStyle.symbol(entry.sfSymbol, pointSize: 11, weight: .medium)
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.bezelStyle = .push
        button.controlSize = .small
        button.bezelColor = .quaternaryLabelColor
        button.tag = entry.index
        button.heightAnchor.constraint(equalToConstant: Metrics.inlineButtonHeight).isActive = true
        let wrapper = NSStackView(views: [button])
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.indent, bottom: 0, right: 0)
        return wrapper
    }

    private func addFullWidth(_ view: NSView, indent: CGFloat = 0) {
        let wrapper = NSStackView(views: [view])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        content.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -(content.edgeInsets.left + content.edgeInsets.right)).isActive = true
        view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor).isActive = true
    }

    // MARK: Actions

    private var entries: [LeoPluginActionEntry] { LeoPluginActionPresentation.entries(for: group.actions) }

    private func actionsMenu() -> NSMenu? {
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: #selector(menuChosen(_:)), keyEquivalent: "")
            item.target = self
            item.image = LeoPluginRenderStyle.symbol(entry.sfSymbol, pointSize: 12)
            item.tag = entry.index
            menu.addItem(item)
        }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? { actionsMenu() }

    @objc private func showActionsMenu(_ sender: NSButton) {
        actionsMenu()?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func menuChosen(_ sender: NSMenuItem) { perform(index: sender.tag, origin: .click) }
    @objc private func inlineChosen(_ sender: NSButton) { perform(index: sender.tag, origin: .click) }

    private func perform(index: Int, origin: LeoPluginGesture.Origin) {
        guard let entry = entries.first(where: { $0.index == index }) else { return }
        emitter.emit(entry.action, origin: origin)
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { !group.actions.isEmpty }
    override var focusRingMaskBounds: NSRect { background.frame }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: background.frame, xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius).fill()
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn, !entries.isEmpty else { return super.keyDown(with: event) }
        if event.modifierFlags.contains(.command) { showActionPanel() } else { perform(index: 0, origin: .keyboard) }
    }

    private func showActionPanel() {
        panel?.close()
        let controller = LeoPluginActionPanelController(entries: entries) { [weak self] index, origin in
            self?.panel?.close()
            self?.perform(index: index, origin: origin)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        panel = popover
        popover.show(relativeTo: background.frame, of: self, preferredEdge: .maxX)
    }

    // MARK: Drawing and accessibility

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor
            if #available(macOS 14.0, *) { fill = .quaternarySystemFill } else { fill = .quaternaryLabelColor }
            background.layer?.backgroundColor = fill.cgColor
        }
    }

    private func applyAccessibility() {
        let state = group.accessory.map { ", \($0.text)" } ?? ""
        setAccessibilityLabel(group.title + state)
        setAccessibilityHelp(group.subtitle)
        setAccessibilityCustomActions(entries.map { entry in
            NSAccessibilityCustomAction(name: entry.title) { [weak self] in
                self?.perform(index: entry.index, origin: .keyboard)
                return true
            }
        })
        let meters: [NSView] = content.arrangedSubviews.flatMap(\.subviews).filter { $0 is LeoPluginValueMeterView }
        setAccessibilityChildren(meters)
    }
}
