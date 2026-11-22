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
        static let focusRingWidth: CGFloat = 1.5
    }

    /// What a rebuild depends on. While it is unchanged an update refreshes the
    /// live views, so meter fills animate and VoiceOver keeps its place.
    private struct Structure: Equatable {
        enum Child: Equatable { case meter, accessory }
        let children: [Child]
        let hasSubtitle: Bool
        let hasAccessory: Bool
        let hasActions: Bool

        init(_ group: LeoPluginNode.Group) {
            children = group.children.map { if case .meter = $0 { .meter } else { .accessory } }
            hasSubtitle = !(group.subtitle ?? "").isEmpty
            hasAccessory = group.accessory != nil
            hasActions = !group.actions.isEmpty
        }

        var showsInlineAction: Bool { hasActions && !children.contains(.meter) }
    }

    private let emitter: LeoPluginActionEmitter
    private(set) var group: LeoPluginNode.Group
    private let background = NSView()
    private let content = NSStackView()
    private var panel: NSPopover?
    private var structure: Structure?
    private let symbolView = NSImageView()
    private let titleLabel = LeoPluginRenderStyle.label("", font: .systemFont(ofSize: 13, weight: .semibold))
    private var headerAccessory: LeoPluginAccessoryView?
    private var subtitleLabel: NSTextField?
    private var childViews: [NSView] = []
    private var inlineActionButton: NSButton?
    private var isKeyboardFocused = false {
        didSet { if isKeyboardFocused != oldValue { applyBackground() } }
    }

    /// The Group's meters, for the slot's shared label column.
    var meterViews: [LeoPluginValueMeterView] { childViews.compactMap { $0 as? LeoPluginValueMeterView } }

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
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.setAccessibilityElement(false)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        focusRingType = .none  // drawn by applyBackground, per design.md
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
        let next = Structure(group)
        if next == structure { refresh() } else { rebuild(next) }
        structure = next
        applyAccessibility()
        applyBackground()
    }

    // MARK: Building

    private func rebuild(_ structure: Structure) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        headerAccessory = group.accessory.map { LeoPluginAccessoryView(accessory: $0) }
        addFullWidth(headerRow())
        subtitleLabel = nil
        if structure.hasSubtitle {
            let label = LeoPluginRenderStyle.label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, lines: 2)
            label.setAccessibilityElement(false)
            // Wraps to the Group's width instead of widening it (design.md: two lines, then tail).
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            subtitleLabel = label
            addFullWidth(label, indent: Metrics.indent)
            content.setCustomSpacing(2, after: content.arrangedSubviews[0])
        }
        childViews = group.children.map { child -> NSView in
            switch child {
            case .meter(let meter): LeoPluginValueMeterView(meter: meter, style: .regular)
            case .accessory(let accessory): LeoPluginAccessoryView(accessory: accessory)
            }
        }
        childViews.forEach { addFullWidth($0, indent: Metrics.indent) }
        inlineActionButton = nil
        if structure.showsInlineAction, let first = entries.first {
            content.addArrangedSubview(inlineButton(first))
        }
        refresh()
    }

    /// Puts the current Group's values into the live views.
    private func refresh() {
        symbolView.image = LeoPluginRenderStyle.symbol(group.sfSymbol, pointSize: 13) ?? NSImage()
        titleLabel.stringValue = group.title
        titleLabel.toolTip = group.title
        if let accessory = group.accessory { headerAccessory?.update(accessory: accessory) }
        subtitleLabel?.stringValue = group.subtitle ?? ""
        for (view, child) in zip(childViews, group.children) {
            switch (view, child) {
            case (let meterView as LeoPluginValueMeterView, .meter(let meter)): meterView.update(meter: meter)
            case (let accessoryView as LeoPluginAccessoryView, .accessory(let accessory)): accessoryView.update(accessory: accessory)
            default: break
            }
        }
        if let button = inlineActionButton, let first = entries.first { configure(button, with: first) }
    }

    private func headerRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.symbolGap
        symbolView.widthAnchor.constraint(equalToConstant: Metrics.symbolColumn).isActive = true
        row.addArrangedSubview(symbolView)
        row.addArrangedSubview(titleLabel)
        if let headerAccessory { row.addArrangedSubview(headerAccessory) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)
        if !group.actions.isEmpty { row.addArrangedSubview(menuButton()) }
        return row
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
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.bezelStyle = .push
        button.controlSize = .small
        button.bezelColor = .quaternaryLabelColor
        configure(button, with: entry)
        inlineActionButton = button
        button.heightAnchor.constraint(equalToConstant: Metrics.inlineButtonHeight).isActive = true
        let wrapper = NSStackView(views: [button])
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.indent, bottom: 0, right: 0)
        return wrapper
    }

    private func configure(_ button: NSButton, with entry: LeoPluginActionEntry) {
        button.title = entry.title
        button.image = LeoPluginRenderStyle.symbol(entry.sfSymbol, pointSize: 11, weight: .medium)
        button.tag = entry.index
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

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { isKeyboardFocused = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { isKeyboardFocused = false }
        return resigned
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

    /// Focused (design.md): the unemphasized selection fill and a 1.5 pt ring
    /// in the keyboard focus colour, following the corner radius.
    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let resting: NSColor
            if #available(macOS 14.0, *) { resting = .quaternarySystemFill } else { resting = .quaternaryLabelColor }
            let layer = background.layer
            layer?.backgroundColor = (isKeyboardFocused ? NSColor.unemphasizedSelectedContentBackgroundColor : resting).cgColor
            layer?.borderWidth = isKeyboardFocused ? Metrics.focusRingWidth : 0
            layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
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
        setAccessibilityChildren(meterViews)
    }
}
