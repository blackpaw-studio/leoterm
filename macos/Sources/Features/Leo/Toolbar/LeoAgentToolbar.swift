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

    /// Builds the capsule's view when the toolbar asks for the item (set
    /// before `install`).
    var makeActivityView: () -> NSView = { NSView() }
    private weak var toolbar: NSToolbar?
    private weak var window: NSWindow?
    private weak var splitView: NSSplitView?
    private var subscriptions: Set<AnyCancellable> = []
    private(set) weak var sidebarToggle: NSToolbarItem?
    private weak var activityItem: NSToolbarItem?
    /// What the bindings last said, so an item AppKit builds later starts right.
    private var isSidebarToggleHidden = true
    private var hasActivity = false

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
        self.window = window
        observeLayout(of: window, splitView: nil)
    }

    deinit {
        layoutObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Keeps the sidebar toggle visible exactly while the sidebar is
    /// collapsed.
    @MainActor
    func bind(sidebarVisible: some Publisher<Bool, Never>) {
        sidebarVisible.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] isVisible in
            guard let self else { return }
            isSidebarToggleHidden = isVisible
            if #available(macOS 15.0, *) { sidebarToggle?.isHidden = isVisible }
        }.store(in: &subscriptions)
    }

    /// Shows the capsule while the selected agent has a task; hidden, it
    /// leaves no gap.
    @MainActor
    func bind(hasActivity: some Publisher<Bool, Never>) {
        hasActivity.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] hasActivity in
            guard let self else { return }
            self.hasActivity = hasActivity
            if #available(macOS 15.0, *) { activityItem?.isHidden = !hasActivity }
        }.store(in: &subscriptions)
    }

    /// The split view is in the window: the tracking separator can join.
    @MainActor
    func attach(splitView: NSSplitView) {
        guard self.splitView == nil, let toolbar else { return }
        self.splitView = splitView
        if let window { observeLayout(of: window, splitView: splitView) }
        updateActivityWidth()
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
        case .leoActivity: makeActivityItem()
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
        // Hidden unless the session reports the sidebar collapsed.
        if #available(macOS 15.0, *) { item.isHidden = isSidebarToggleHidden }
        return item
    }

    private var activityWidth: NSLayoutConstraint?
    private var layoutObservers: [NSObjectProtocol] = []

    private func makeActivityItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .leoActivity)
        let host = makeActivityView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let width = host.widthAnchor.constraint(equalToConstant: LeoActivityCapsulePresentation.maxWidth)
        activityWidth = width
        NSLayoutConstraint.activate([width, host.heightAnchor.constraint(equalToConstant: LeoActivityCapsule.height)])
        item.view = host
        // The capsule draws its own 32 pt glass: AppKit's platter is a fixed 36 pt.
        item.isBordered = false
        item.visibilityPriority = .high
        item.label = "Activity"
        if #available(macOS 15.0, *) { item.isHidden = !hasActivity }
        activityItem = item
        updateActivityWidth()
        return item
    }

    /// Sizes the capsule from the room right of the sidebar
    /// (`LeoActivityCapsuleSizing`); on every window or split resize.
    private func updateActivityWidth() {
        guard let activityWidth, let window else { return }
        let sidebar = splitView?.arrangedSubviews.first.map { $0.isHidden ? 0 : $0.frame.maxX } ?? 0
        let width = LeoActivityCapsuleSizing.width(availableToolbarWidth: window.frame.width - sidebar)
        if activityWidth.constant != width { activityWidth.constant = width }
    }

    private func observeLayout(of window: NSWindow, splitView: NSSplitView?) {
        layoutObservers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        let update: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.updateActivityWidth() } }
        layoutObservers = [center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: update)]
        if let splitView {
            layoutObservers.append(
                center.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main, using: update))
        }
    }

    private func makeMorePlaceholder() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .leoMore)
        item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        item.label = "More"
        // The first to fold into the overflow chevron when the window is narrow.
        item.visibilityPriority = .low
        return item
    }
}
