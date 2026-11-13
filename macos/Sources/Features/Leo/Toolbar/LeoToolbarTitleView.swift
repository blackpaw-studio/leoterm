import AppKit

/// What the toolbar's title item shows: the window title, the agent's
/// `<cwd> · <harness>` under it (empty: none), and whether its menu opens.
struct LeoToolbarTitlePresentation: Equatable {
    var title = ""
    var subtitle = ""
    /// False with no agent shown: the title stays, its menu doesn't open.
    var isEnabled = false
}

/// The toolbar's title item: the window title with the agent's subtitle
/// under it and a ▾, a pull-down for the agent's actions. It stands in for
/// the window's own title (`titleVisibility = .hidden`), set in the same
/// type as the system's: semibold 13 pt over regular 11 pt secondary.
@MainActor
final class LeoToolbarTitleView: NSView {
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let subtitleFont = NSFont.systemFont(ofSize: 11)
    private static let chevronGap: CGFloat = 3

    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var widthConstraint = NSLayoutConstraint()
    private(set) var presentation = LeoToolbarTitlePresentation()
    /// The pull-down, built fresh each time it opens.
    var pullDown: NSMenu?

    init() {
        super.init(frame: .zero)
        widthConstraint = widthAnchor.constraint(equalToConstant: LeoActivityCapsuleSizing.maxTitleWidth)
        translatesAutoresizingMaskIntoConstraints = false
        titleField.font = Self.titleFont
        titleField.textColor = .labelColor
        subtitleField.font = Self.subtitleFont
        subtitleField.textColor = .secondaryLabelColor
        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(field)
        }
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: 34),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            chevron.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: Self.chevronGap),
            chevron.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            chevron.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            subtitleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor),
        ])
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Agent actions")
        apply(presentation)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { !presentation.isEnabled }

    /// Sets the item's width (0 hides the title: the window's width has no room for it).
    func setWidth(_ width: CGFloat) {
        let hidden = width <= 0
        if isHidden != hidden { isHidden = hidden }
        if widthConstraint.constant != width { widthConstraint.constant = max(0, width) }
    }

    func apply(_ presentation: LeoToolbarTitlePresentation) {
        self.presentation = presentation
        titleField.stringValue = presentation.title
        subtitleField.stringValue = presentation.subtitle
        subtitleField.isHidden = presentation.subtitle.isEmpty
        chevron.isHidden = !presentation.isEnabled
        alphaValue = presentation.isEnabled ? 1 : 0.9
        setAccessibilityValue(presentation.title)
        setAccessibilityEnabled(presentation.isEnabled)
        toolTip = presentation.isEnabled ? "Agent actions" : nil
    }

    /// The title text and ▾: the empty room to their right drags the window like the rest of the toolbar.
    private var contentWidth: CGFloat {
        let text = max(titleField.fittingSize.width, subtitleField.isHidden ? 0 : subtitleField.fittingSize.width)
        return min(bounds.width, text + Self.chevronGap + (chevron.image?.size.width ?? 0))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard presentation.isEnabled, bounds.contains(convert(point, from: superview)) else { return nil }
        return convert(point, from: superview).x <= contentWidth ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard presentation.isEnabled, let menu = pullDown else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: self)
    }

    override func accessibilityPerformPress() -> Bool {
        guard presentation.isEnabled, let menu = pullDown else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: self)
        return true
    }
}
