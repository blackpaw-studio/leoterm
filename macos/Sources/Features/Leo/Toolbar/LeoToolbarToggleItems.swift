import AppKit

/// The toolbar's three tool toggles (Files, Browser, Agent Pane): plain
/// bordered items, so AppKit draws them side by side in one glass group
/// (as it does Interrupt and "⋯"). A one-segment `NSToolbarItemGroup` per
/// toggle was tried first and gave each toggle a glass capsule of its own.
///
/// An item has no on state of its own, so the lit toggle is the prominent
/// style on macOS 26 and an accent-tinted symbol before that.
///
/// The toggles hold no panel state: a click sends the toggle's action down
/// the responder chain, and the panel's own state, pushed back through
/// `apply`, decides what is lit.
@MainActor
final class LeoToolbarToggleItems: NSObject {
    struct Spec {
        let identifier: NSToolbarItem.Identifier
        let symbol: String
        let action: Selector
        let tool: KeyPath<LeoToolbarToolState, LeoToolbarToolState.Tool>
    }

    static let specs: [Spec] = [
        Spec(identifier: .leoFiles, symbol: "folder", action: #selector(TerminalController.toggleLeoFilesPanel(_:)), tool: \.files),
        Spec(identifier: .leoBrowser, symbol: "globe", action: #selector(TerminalController.toggleLeoAgentBrowser(_:)), tool: \.browser),
        Spec(
            identifier: .leoAgentPane, symbol: "rectangle.bottomthird.inset.filled",
            action: #selector(TerminalController.toggleLeoAgentPane(_:)), tool: \.agentPane),
    ]

    /// Sends a toggle's action to whoever handles it: the responder chain.
    var send: (Selector, Any?) -> Void = { action, sender in NSApp.sendAction(action, to: nil, from: sender) }

    private(set) var state = LeoToolbarToolState.none
    /// The toolbar has no room for the toggles beside the capsule.
    private(set) var isFolded = false
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]

    func makeItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard let spec = Self.specs.first(where: { $0.identifier == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        let label = LeoAgentToolbarItems.paletteLabel(for: identifier) ?? ""
        item.label = label
        item.paletteLabel = label
        item.isBordered = true
        item.target = self
        item.action = #selector(clicked(_:))
        item.visibilityPriority = LeoAgentToolbarItems.visibilityPriority(for: identifier)
        item.autovalidates = false
        items[identifier] = item
        sync(item, spec)
        syncVisibility(item)
        return item
    }

    /// Lights and enables the toggles to match `state`.
    func apply(_ state: LeoToolbarToolState) {
        self.state = state
        for spec in Self.specs { items[spec.identifier].map { sync($0, spec) } }
    }

    /// Hides the toggles while the toolbar has no room for them (macOS 15
    /// and later; before that they fold into the overflow by priority). The
    /// Browser toggle is also hidden while the Agent browser setting is off.
    func setFolded(_ isFolded: Bool) {
        guard self.isFolded != isFolded else { return }
        self.isFolded = isFolded
        items.values.forEach(syncVisibility)
    }

    /// Hides the Browser toggle while the setting is off, and every toggle while folded.
    func syncVisibility() { items.values.forEach(syncVisibility) }

    private func syncVisibility(_ item: NSToolbarItem) {
        guard #available(macOS 15.0, *) else { return }
        let isHidden = isFolded || (item.itemIdentifier == .leoBrowser && !state.browser.isPresent)
        if item.isHidden != isHidden { item.isHidden = isHidden }
    }

    private func sync(_ item: NSToolbarItem, _ spec: Spec) {
        let tool = state[keyPath: spec.tool]
        if item.isEnabled != tool.isEnabled { item.isEnabled = tool.isEnabled }
        let label = LeoAgentToolbarItems.paletteLabel(for: spec.identifier) ?? ""
        item.image = Self.image(spec.symbol, label: label, isOn: tool.isOn)
        if #available(macOS 26.0, *) {
            let style: NSToolbarItem.Style = tool.isOn ? .prominent : .plain
            if item.style != style { item.style = style }
        }
        item.toolTip = Self.tooltip(for: spec.identifier, isOn: tool.isOn)
    }

    /// Before macOS 26 there is no prominent style: the lit toggle's symbol takes the accent colour.
    private static func image(_ symbol: String, label: String, isOn: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        guard isOn, #unavailable(macOS 26.0) else { return image }
        return image?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
    }

    private static func tooltip(for identifier: NSToolbarItem.Identifier, isOn: Bool) -> String? {
        let base = LeoAgentToolbarItems.tooltip(for: identifier)
        return isOn ? base?.replacingOccurrences(of: "Show", with: "Hide") : base
    }

    @objc private func clicked(_ sender: NSToolbarItem) {
        guard let spec = Self.specs.first(where: { $0.identifier == sender.itemIdentifier }) else { return }
        send(spec.action, sender)
    }
}
