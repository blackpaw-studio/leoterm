import AppKit

/// The toolbar's Terminal | Chat switch: a system segmented control with two
/// SF Symbol segments, drawn by AppKit on its own glass group. It mirrors a
/// `LeoViewSwitchPresentation` and reports clicks as view choices; it holds
/// no view state of its own, so after a click it snaps back to what is shown
/// until the session changes the choice.
///
/// `.selectAny`: side by side both segments are lit, and clicking Chat while
/// it shows closes it (the session decides, via `LeoViewMenuActions`).
@MainActor
final class LeoToolbarViewSwitch: NSSegmentedControl {
    private(set) var presentation = LeoViewSwitchPresentation(layout: nil, unreadCount: 0)
    /// Called with the clicked segment's choice.
    var onSelect: (LeoAgentViewChoice) -> Void = { _ in }
    var showsUnreadDot: Bool { presentation.showsUnreadDot }

    override class var cellClass: AnyClass? {
        get { LeoViewSwitchCell.self }
        set {}
    }

    init() {
        super.init(frame: .zero)
        segmentCount = LeoViewSwitchPresentation.choices.count
        trackingMode = .selectAny
        segmentStyle = .automatic
        // A click must never take focus from the terminal surface.
        refusesFirstResponder = true
        target = self
        action = #selector(clicked(_:))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityLabel(LeoViewSwitchPresentation.groupLabel)
        for (index, tooltip) in LeoViewSwitchPresentation.tooltips.enumerated() { setToolTip(tooltip, forSegment: index) }
        apply(presentation)
    }

    /// A click must never take focus from the terminal surface, whatever the
    /// control's own rules for first-responder status.
    override var acceptsFirstResponder: Bool { false }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ presentation: LeoViewSwitchPresentation) {
        self.presentation = presentation
        isEnabled = presentation.isEnabled
        (cell as? LeoViewSwitchCell)?.segmentLabels = [LeoViewSwitchPresentation.tooltips[0], presentation.chatAccessibilityLabel]
        setImage(LeoViewSwitchImages.terminal(), forSegment: 0)
        setImage(LeoViewSwitchImages.chat(showsDot: presentation.showsUnreadDot, label: presentation.chatAccessibilityLabel), forSegment: 1)
        syncSelection()
    }

    private func syncSelection() {
        for (index, choice) in LeoViewSwitchPresentation.choices.enumerated() {
            setSelected(presentation.selected.contains(choice), forSegment: index)
        }
    }

    @objc private func clicked(_ sender: NSSegmentedControl) {
        let states = (0..<segmentCount).map { isSelected(forSegment: $0) }
        let choice = presentation.clicked(segmentStates: states)
        syncSelection()
        if let choice { onSelect(choice) }
    }
}

/// The segmented cell, whose segment accessibility elements VoiceOver reads
/// by their own label: the image's description isn't enough, and "Chat, n
/// unread" has to be there.
private final class LeoViewSwitchCell: NSSegmentedCell {
    var segmentLabels: [String] = []

    override func accessibilityChildren() -> [Any]? {
        let segments = super.accessibilityChildren()
        for (index, segment) in (segments ?? []).enumerated() where index < segmentLabels.count {
            (segment as? NSObject)?.perform(Selector(("setAccessibilityLabel:")), with: segmentLabels[index])
        }
        return segments
    }
}

/// The switch's segment images. Terminal is a template symbol (AppKit tints
/// it, white on the accent fill). Chat with unread is composed by hand,
/// glyph plus an accent dot at its top-right: a template would tint the dot
/// away. The glyph colour is resolved when drawn, so it follows light and
/// dark. The dot only shows while Chat is not lit, so the glyph is never
/// drawn on the accent fill.
@MainActor
enum LeoViewSwitchImages {
    private static let dotDiameter: CGFloat = 6

    static func terminal() -> NSImage {
        symbol("terminal", description: LeoViewSwitchPresentation.tooltips[0])
    }

    static func chat(showsDot: Bool, label: String) -> NSImage {
        let base = symbol("bubble.left", description: label)
        return showsDot ? withDot(base, description: label) : base
    }

    private static func symbol(_ name: String, description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage(size: NSSize(width: 16, height: 16))
    }

    private static func withDot(_ base: NSImage, description: String) -> NSImage {
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            let glyph = NSImage(size: size, flipped: false) { glyphRect in
                base.draw(in: glyphRect)
                NSColor.labelColor.set()
                glyphRect.fill(using: .sourceAtop)
                return true
            }
            glyph.draw(in: rect)
            NSColor.controlAccentColor.setFill()
            let dot = NSRect(x: rect.maxX - dotDiameter, y: rect.maxY - dotDiameter, width: dotDiameter, height: dotDiameter)
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = description
        return image
    }
}
