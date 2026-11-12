import AppKit

/// The pane's 30 pt tab bar: the tabs, a "+N" menu for tabs that don't fit,
/// and the chevron. What each tab draws is `LeoAgentPaneTabLayout`'s call.
final class LeoAgentPaneTabBarView: NSView {
    private static let spacing: CGFloat = 4
    private static let trailingWidth: CGFloat = 28
    private static let overflowWidth: CGFloat = 36
    private static let inset: CGFloat = 6

    private(set) var tabViews: [LeoAgentPaneTabView] = []
    private var selectedID: String?
    private let overflow = NSButton(title: "", target: nil, action: nil)
    private let chevron = NSButton(title: "", target: nil, action: nil)
    private let separator = NSBox()
    var onTapTab: (String) -> Void = { _ in }
    var onToggle: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        overflow.bezelStyle = .accessoryBarAction
        overflow.isBordered = false
        overflow.font = .systemFont(ofSize: 11, weight: .medium)
        overflow.target = self
        overflow.action = #selector(showOverflowMenu)
        overflow.toolTip = "More tabs"
        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.target = self
        chevron.action = #selector(toggle)
        separator.boxType = .separator
        [overflow, chevron, separator].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Replaces the tabs (the views, so their summary hosts, are the caller's to keep stable).
    func setTabs(_ views: [LeoAgentPaneTabView], selected: String?, isExpanded: Bool) {
        if views.map(\.tab) != tabViews.map(\.tab) || views.contains(where: { v in !tabViews.contains { $0 === v } }) {
            tabViews.forEach { $0.removeFromSuperview() }
            tabViews = views
            for view in views {
                view.onTap = { [weak self] in self?.onTapTab(view.tab.id) }
                addSubview(view, positioned: .below, relativeTo: overflow)
            }
        }
        selectedID = selected
        let symbol = isExpanded ? "chevron.down" : "chevron.up"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: isExpanded ? "Collapse agent pane" : "Expand agent pane")
        chevron.toolTip = isExpanded ? "Collapse" : "Expand"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = LeoAgentPaneState.collapsedHeight
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        chevron.frame = NSRect(x: bounds.width - Self.trailingWidth, y: 0, width: Self.trailingWidth, height: height)
        let room = max(0, bounds.width - Self.trailingWidth - Self.inset)
        let fit = LeoAgentPaneTabLayout.fit(
            tabs: tabViews.map(\.measuredTab), selected: selectedID, width: Double(room - Self.inset),
            spacing: Double(Self.spacing), overflowWidth: Double(Self.overflowWidth))
        var x = Self.inset
        for (view, entry) in zip(tabViews, fit.entries) {
            view.isHidden = entry.presentation == .overflow
            guard entry.presentation != .overflow else { continue }
            let measured = view.measuredTab
            let width = CGFloat(entry.presentation == .full ? measured.fullWidth : measured.titleWidth)
            view.update(isSelected: view.tab.id == selectedID, showsSummary: entry.presentation == .full)
            view.frame = NSRect(x: x, y: 3, width: min(width, max(0, room - x)), height: height - 6)
            x += width + Self.spacing
        }
        overflow.isHidden = fit.overflowLabel == nil
        overflow.title = fit.overflowLabel ?? ""
        overflow.frame = NSRect(x: x, y: 0, width: Self.overflowWidth, height: height)
        overflowedTabs = zip(tabViews, fit.entries).filter { $0.1.presentation == .overflow }.map(\.0.tab)
    }

    private var overflowedTabs: [LeoAgentPaneTab] = []

    @objc private func showOverflowMenu() {
        let menu = NSMenu()
        for tab in overflowedTabs {
            let item = NSMenuItem(title: tab.title, action: #selector(pickOverflowTab(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tab.id
            item.image = tab.hasWarning ? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Not running") : nil
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height), in: overflow)
    }

    @objc private func pickOverflowTab(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { onTapTab(id) }
    }

    @objc private func toggle() { onToggle() }
}
