import AppKit
import Combine

extension NSToolbarItem.Identifier {
    static let leoSidebarToggle = NSToolbarItem.Identifier("leo.toolbar.sidebarToggle")
    static let leoSplitSeparator = NSToolbarItem.Identifier("leo.toolbar.splitSeparator")
    static let leoActivity = NSToolbarItem.Identifier("leo.toolbar.activity")
    static let leoMore = NSToolbarItem.Identifier("leo.toolbar.more")
}

/// The agent window's toolbar: the sidebar toggle (shown only while the
/// sidebar is collapsed), a tracking separator that keeps the title and the
/// items over the detail column, the activity capsule centred, and a "⋯"
/// menu trailing.
///
/// The tracking separator needs the window's `NSSplitView`, which exists
/// only after SwiftUI's first layout, so the toolbar goes up at once (the
/// sidebar's inset needs its height) and the separator joins when the split
/// hands itself over (`attach(splitView:)`).
final class LeoAgentToolbar: NSObject, NSToolbarDelegate {
    /// The items in order once the split has been handed over.
    static let itemOrder: [NSToolbarItem.Identifier] = [
        .leoSidebarToggle, .leoSplitSeparator, .flexibleSpace, .leoActivity, .flexibleSpace, .leoMore,
    ]
    /// Toolbars with one identifier are a family: AppKit mirrors item
    /// inserts across them. Each window's separator binds to its own split
    /// view, so every window gets an identifier of its own.
    private static func makeToolbarIdentifier() -> NSToolbar.Identifier {
        NSToolbar.Identifier("leo.agent.toolbar.\(UUID().uuidString)")
    }
    private static let separatorIndex = 1

    private weak var toolbar: NSToolbar?
    private weak var splitView: NSSplitView?
    private var subscriptions: Set<AnyCancellable> = []
    private(set) weak var sidebarToggle: NSToolbarItem?

    @MainActor
    func install(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: Self.makeToolbarIdentifier())
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [.leoActivity]
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        self.toolbar = toolbar
    }

    /// Keeps the sidebar toggle visible exactly while the sidebar is
    /// collapsed.
    @MainActor
    func bind(sidebarVisible: some Publisher<Bool, Never>) {
        sidebarVisible.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] isVisible in
            self?.setSidebarToggleHidden(isVisible)
        }.store(in: &subscriptions)
    }

    private func setSidebarToggleHidden(_ isHidden: Bool) {
        if #available(macOS 15.0, *) { sidebarToggle?.isHidden = isHidden }
    }

    /// The split view is in the window: the tracking separator can join.
    @MainActor
    func attach(splitView: NSSplitView) {
        guard self.splitView == nil, let toolbar else { return }
        self.splitView = splitView
        toolbar.insertItem(withItemIdentifier: .leoSplitSeparator, at: min(Self.separatorIndex, toolbar.items.count))
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemOrder.filter { $0 != .leoSplitSeparator }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemOrder
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .leoSidebarToggle: makeSidebarToggle()
        case .leoSplitSeparator: splitView.map { NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: $0, dividerIndex: 0) }
        case .leoActivity: makeActivityPlaceholder()
        case .leoMore: makeMorePlaceholder()
        default: nil
        }
    }

    private func makeSidebarToggle() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .leoSidebarToggle)
        item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Show Sidebar")
        item.label = "Sidebar"
        item.toolTip = "Show Sidebar"
        item.target = nil
        item.action = #selector(TerminalController.toggleLeoSidebar(_:))
        item.isBordered = true
        sidebarToggle = item
        // Hidden until the session reports the sidebar collapsed.
        if #available(macOS 15.0, *) { item.isHidden = true }
        return item
    }

    private func makeActivityPlaceholder() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .leoActivity)
        item.label = "Activity"
        if #available(macOS 15.0, *) { item.isHidden = true }
        return item
    }

    private func makeMorePlaceholder() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .leoMore)
        item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        item.label = "More"
        return item
    }
}
