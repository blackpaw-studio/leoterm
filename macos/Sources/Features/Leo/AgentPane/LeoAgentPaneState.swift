import CoreGraphics
import Foundation

/// The agent pane's remembered, app-wide state: expanded or collapsed, which
/// tab is selected, and the drawer height. A value type; every transition
/// returns a new state, so the rules are tested without a view.
///
/// The tab list is passed in rather than stored: tabs come and go as plugins
/// are enabled, hidden or crash, and the remembered selection may name a tab
/// that is no longer there. `resolvedSelection(available:)` is what the strip
/// actually shows as selected, and every transition reasons from that.
struct LeoAgentPaneState: Equatable {
    /// The collapsed tab bar's thickness, and the pane's minimum and maximum
    /// thickness while collapsed.
    static let collapsedHeight: CGFloat = 30
    static let minHeight: CGFloat = 120
    static let defaultHeight: CGFloat = 184
    /// The drawer may take at most this fraction of the column.
    static let maxHeightFraction: CGFloat = 0.5

    let isExpanded: Bool
    /// The remembered tab id. It may name a tab that no longer exists.
    let selectedTabID: String?
    /// The remembered drawer height, at least `minHeight`. The upper bound
    /// depends on the column, so it is applied by `displayedHeight(columnHeight:)`.
    let height: CGFloat

    init(isExpanded: Bool = false, selectedTabID: String? = nil, height: CGFloat = LeoAgentPaneState.defaultHeight) {
        self.isExpanded = isExpanded
        self.selectedTabID = selectedTabID
        self.height = height.isFinite ? max(Self.minHeight, height) : Self.defaultHeight
    }

    /// The drawer's largest height in a column this tall. A column too short
    /// for the minimum gets the minimum: usable beats proportional.
    static func maxHeight(columnHeight: CGFloat) -> CGFloat {
        max(minHeight, columnHeight * maxHeightFraction)
    }

    /// The tab the strip shows as selected: the remembered one if it still
    /// exists, otherwise the first.
    func resolvedSelection(available tabs: [String]) -> String? {
        guard let selectedTabID, tabs.contains(selectedTabID) else { return tabs.first }
        return selectedTabID
    }

    /// A tap on a tab. The selected tab toggles the drawer; any other tab
    /// selects it and opens the drawer. An id that isn't a tab is ignored.
    func tappingTab(_ id: String, available tabs: [String]) -> LeoAgentPaneState {
        guard tabs.contains(id) else { return self }
        if isExpanded, resolvedSelection(available: tabs) == id {
            return LeoAgentPaneState(isExpanded: false, selectedTabID: id, height: height)
        }
        return LeoAgentPaneState(isExpanded: true, selectedTabID: id, height: height)
    }

    /// The chevron, and View → "Toggle Agent Pane". Expanding opens the
    /// selected tab; with no tabs there is nothing to open.
    func toggled(available tabs: [String]) -> LeoAgentPaneState {
        guard let selection = resolvedSelection(available: tabs) else { return self }
        return LeoAgentPaneState(isExpanded: !isExpanded, selectedTabID: selection, height: height)
    }

    /// The drawer was dragged to `proposed` in a column `columnHeight` tall.
    func settingHeight(_ proposed: CGFloat, columnHeight: CGFloat) -> LeoAgentPaneState {
        guard proposed.isFinite else { return self }
        let clamped = min(max(Self.minHeight, proposed), Self.maxHeight(columnHeight: columnHeight))
        return LeoAgentPaneState(isExpanded: isExpanded, selectedTabID: selectedTabID, height: clamped)
    }

    /// The remembered height clamped to this column. The remembered value is
    /// untouched, so a window that shrinks and grows back restores it.
    func displayedHeight(columnHeight: CGFloat) -> CGFloat {
        min(height, Self.maxHeight(columnHeight: columnHeight))
    }
}

/// Reads and writes `LeoAgentPaneState` through an injected `UserDefaults`
/// (tests pass a throwaway suite; `.standard` would be shared across runs).
/// Each field falls back to its default on its own when the stored value is
/// missing or the wrong type.
struct LeoAgentPaneStateStore {
    enum Keys {
        static let expanded = "leo.agentPane.expanded"
        static let selectedTab = "leo.agentPane.selectedTab"
        static let height = "leo.agentPane.height"
    }

    let defaults: UserDefaults

    func load() -> LeoAgentPaneState {
        LeoAgentPaneState(
            isExpanded: defaults.object(forKey: Keys.expanded) as? Bool ?? false,
            selectedTabID: defaults.object(forKey: Keys.selectedTab) as? String,
            height: (defaults.object(forKey: Keys.height) as? Double).map { CGFloat($0) }
                ?? LeoAgentPaneState.defaultHeight)
    }

    func save(_ state: LeoAgentPaneState) {
        defaults.set(state.isExpanded, forKey: Keys.expanded)
        defaults.set(state.selectedTabID, forKey: Keys.selectedTab)
        defaults.set(Double(state.height), forKey: Keys.height)
    }
}
