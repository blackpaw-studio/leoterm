import AppKit

extension NSToolbarItem.Identifier {
    static let leoTitleMenu = NSToolbarItem.Identifier("leo.toolbar.titleMenu")
    static let leoFiles = NSToolbarItem.Identifier("leo.toolbar.files")
    static let leoBrowser = NSToolbarItem.Identifier("leo.toolbar.browser")
    static let leoAgentPane = NSToolbarItem.Identifier("leo.toolbar.agentPane")
}

/// The agent toolbar's item model: the default set and its order, what the
/// user can and cannot remove, the palette's labels and tooltips, where an
/// item may be dropped, and which items fold into the overflow first. Pure:
/// the delegate reads it and applies it to AppKit.
enum LeoAgentToolbarItems {
    typealias Identifier = NSToolbarItem.Identifier

    /// The items in order once the split view has been handed over.
    static let defaultOrder: [Identifier] = [
        .leoSidebarToggle, .leoSplitSeparator, .leoTitleMenu, .flexibleSpace, .leoActivity, .flexibleSpace,
        .leoResetZoom, .leoUpdate, .leoFiles, .leoBrowser, .leoAgentPane, .leoViewSwitch, .leoInterrupt, .leoMore,
    ]

    /// Items the user can't drag out. The title, the switch and "⋯" are
    /// always there; the rest are shown and hidden by the app itself (the
    /// sidebar toggle, the split separator, the update pill, reset zoom).
    static let immovable: Set<Identifier> = [
        .leoTitleMenu, .leoViewSwitch, .leoMore, .leoSidebarToggle, .leoSplitSeparator, .leoUpdate, .leoResetZoom,
    ]

    /// Items the app shows, hides and places itself, from window state. A
    /// saved layout never records them (`LeoToolbarLayoutStore`).
    static let appManaged: Set<Identifier> = [.leoSidebarToggle, .leoSplitSeparator, .leoUpdate, .leoResetZoom]

    /// What the palette offers: every item but the tracking separator.
    static let paletteOrder: [Identifier] = defaultOrder.filter { $0 != .leoSplitSeparator && $0 != .flexibleSpace }

    private static let paletteLabels: [Identifier: String] = [
        .leoTitleMenu: "Agent", .leoSidebarToggle: "Sidebar", .leoActivity: "Status", .leoResetZoom: "Reset Zoom",
        .leoUpdate: "Update", .leoFiles: "Files", .leoBrowser: "Browser", .leoAgentPane: "Agent Pane",
        .leoViewSwitch: "View", .leoInterrupt: "Interrupt", .leoMore: "More",
    ]

    private static let tooltips: [Identifier: String] = [
        .leoTitleMenu: "Agent actions", .leoSidebarToggle: "Show Sidebar", .leoActivity: "Agent status",
        .leoResetZoom: "Reset Split Zoom", .leoUpdate: "Update status", .leoFiles: "Show Files",
        .leoBrowser: "Show Agent Browser", .leoAgentPane: "Show Agent Pane", .leoViewSwitch: "Terminal or Chat",
        .leoInterrupt: "Interrupt", .leoMore: "More actions",
    ]

    static func paletteLabel(for identifier: Identifier) -> String? { paletteLabels[identifier] }
    static func tooltip(for identifier: Identifier) -> String? { tooltips[identifier] }

    /// Nothing the user drops may land before the title: the leading edge is
    /// the app's (sidebar toggle, separator, title). With no title in the
    /// toolbar there is nothing to guard.
    static func canInsert(_ identifier: Identifier, at index: Int, in current: [Identifier]) -> Bool {
        guard let title = current.firstIndex(of: .leoTitleMenu) else { return true }
        return index > title
    }

    /// The toggles fold into the overflow first, then Interrupt; the rest
    /// go last (`.user`). The capsule, update pill and reset-zoom button keep
    /// the priorities they set themselves.
    static func visibilityPriority(for identifier: Identifier) -> NSToolbarItem.VisibilityPriority {
        switch identifier {
        case .leoFiles, .leoBrowser, .leoAgentPane: .low
        case .leoInterrupt: .standard
        default: .user
        }
    }
}
