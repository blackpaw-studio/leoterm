import AppKit
import LeoKit

/// A tab's summary: drawn after the title when there is room. The plugin
/// slot host is one; the Terminal's directory label is another.
@MainActor protocol LeoAgentPaneSummaryView: NSView {
    /// Its natural size (width 0 while there is nothing to show), for the tab bar's overflow fit.
    var summaryWidth: CGFloat { get }
    var summaryHeight: CGFloat { get }
}

extension LeoPluginSlotHostView: LeoAgentPaneSummaryView {}

/// One tab in the pane's bar: an icon (a warning glyph for a crashed plugin),
/// the plugin's title and, when there is room, its summary. A click anywhere
/// on it taps the tab.
final class LeoAgentPaneTabView: NSView {
    static let height = LeoAgentPaneState.collapsedHeight
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 5

    let tab: LeoAgentPaneTab
    let summary: (any LeoAgentPaneSummaryView)?
    var onTap: () -> Void = {}
    private let icon = NSImageView()
    private let title: NSTextField
    private var isSelected = false
    /// Whether the summary is drawn; the tab bar turns it off when it needs the room.
    private(set) var showsSummary = false

    init(tab: LeoAgentPaneTab, summary: (any LeoAgentPaneSummaryView)?) {
        self.tab = tab
        self.summary = summary
        title = LeoPluginRenderStyle.label(tab.title, font: .systemFont(ofSize: 12, weight: .medium))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        let iconName = tab.iconName { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
        icon.image = LeoPluginRenderStyle.symbol(iconName, pointSize: 11, weight: .medium)
        icon.contentTintColor = tab.hasWarning ? .systemOrange : .secondaryLabelColor
        title.textColor = tab.hasWarning ? .secondaryLabelColor : .labelColor
        [icon, title].forEach(addSubview)
        if let summary { addSubview(summary) }
        toolTip = tab.hasWarning ? "\(tab.title) is not running" : nil
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Measuring (for `LeoAgentPaneTabLayout.fit`)

    private var iconWidth: CGFloat { icon.image == nil ? 0 : 14 + Self.gap }
    /// Measured from the string and font, not the label's intrinsic size, which
    /// undercounts a truncating label and clips the last characters.
    private var titleWidth: CGFloat {
        ceil(NSAttributedString(string: tab.title, attributes: [.font: title.font as Any]).size().width) + 6
    }

    var measuredTab: LeoAgentPaneTabLayout.Tab {
        let titleOnly = Self.padding * 2 + iconWidth + titleWidth
        let summaryWidth = ceil(summary?.summaryWidth ?? 0)
        let full = summaryWidth > 0 ? titleOnly + Self.gap * 2 + summaryWidth : titleOnly
        return .init(id: tab.id, titleWidth: Double(titleOnly), fullWidth: Double(full))
    }

    // MARK: State

    func update(isSelected: Bool, showsSummary: Bool) {
        self.isSelected = isSelected
        self.showsSummary = showsSummary
        summary?.isHidden = !showsSummary
        needsLayout = true
        updateColors()
        setAccessibilityValue(isSelected ? "Selected" : nil)
    }

    private func updateColors() {
        let fill: NSColor = isSelected ? .quaternaryLabelColor : .clear
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fill.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    // MARK: Layout and clicks

    override func layout() {
        super.layout()
        var x = Self.padding
        let midY = bounds.midY
        if icon.image != nil {
            icon.frame = NSRect(x: x, y: midY - 7, width: 14, height: 14)
            x += 14 + Self.gap
        }
        let labelHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: x, y: midY - labelHeight / 2, width: titleWidth, height: labelHeight)
        x += titleWidth + Self.gap * 2
        guard let summary, showsSummary else { return }
        let width = max(0, bounds.width - x - Self.padding)
        let height = max(ceil(summary.summaryHeight), LeoPluginMeterGeometry.summarySize.height)
        summary.frame = NSRect(x: x, y: midY - height / 2, width: width, height: height)
    }

    /// The whole tab is the button: its labels never take the click.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

    override func mouseDown(with event: NSEvent) { onTap() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onTap(); return true }
}
