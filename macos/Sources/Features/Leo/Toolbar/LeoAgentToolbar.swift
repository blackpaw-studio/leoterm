import AppKit
import Combine

extension NSToolbarItem.Identifier {
    static let leoSidebarToggle = NSToolbarItem.Identifier("leo.toolbar.sidebarToggle")
    static let leoSplitSeparator = NSToolbarItem.Identifier("leo.toolbar.splitSeparator")
    static let leoActivity = NSToolbarItem.Identifier("leo.toolbar.activity")
    static let leoResetZoom = NSToolbarItem.Identifier("leo.toolbar.resetZoom")
    static let leoUpdate = NSToolbarItem.Identifier("leo.toolbar.update")
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
        .leoSidebarToggle, .leoSplitSeparator, .flexibleSpace, .leoActivity, .flexibleSpace, .leoResetZoom, .leoUpdate, .leoMore,
    ]
    /// Toolbars with one identifier are a family: AppKit mirrors item
    /// inserts across them. Each window's separator binds to its own split
    /// view, so every window gets an identifier of its own.
    private static func makeToolbarIdentifier() -> NSToolbar.Identifier {
        NSToolbar.Identifier("leo.agent.toolbar.\(UUID().uuidString)")
    }

    /// Builds the capsule's view when the toolbar asks for the item (set
    /// before `install`).
    var makeActivityView: () -> NSView = { NSView() }
    /// Builds the update pill's view when the toolbar asks for the item (set
    /// before `install`).
    var makeUpdateView: () -> NSView = { NSView() }
    /// The "⋯" item's menu (set before `install`).
    var moreMenu = NSMenu()
    /// Keeps the menu's controller alive: an `NSMenu` holds its delegate weakly.
    var retainedMenu: AnyObject?
    private weak var toolbar: NSToolbar?
    private weak var window: NSWindow?
    private weak var splitView: NSSplitView?
    private var subscriptions: Set<AnyCancellable> = []
    private(set) weak var sidebarToggle: NSToolbarItem?
    private weak var activityItem: NSToolbarItem?
    /// What the bindings last said, so an item AppKit builds later starts right.
    /// Whether the window subtitle has room beside the capsule; the owner
    /// of the subtitle reads it (`onSubtitleVisibilityChange` says when it flips).
    private(set) var showsSubtitle = true
    var onSubtitleVisibilityChange: () -> Void = {}
    private weak var moreItem: NSToolbarItem?
    private weak var updateItem: NSToolbarItem?
    private weak var resetZoomItem: NSToolbarItem?
    private var isSurfaceZoomed = false
    private var isUpdateShowing = false
    private var showsUpdateItem = true
    /// Whether `NSToolbarItem.isHidden` takes effect (macOS 15+). Below that
    /// the items that come and go are inserted and removed instead; tests
    /// turn this off (before `install`) to exercise that path here.
    var hidesItemsInPlace: Bool = {
        if #available(macOS 15.0, *) { return true }
        return false
    }()
    /// The gap the toolbar keeps around the update pill.
    static let updateItemSpacing: CGFloat = 10
    /// What the reset-zoom button (a 28 pt bordered item) takes right of the
    /// capsule, with the toolbar's spacing.
    static let resetZoomReserve: CGFloat = 38
    private var showsMoreItem = true
    private var isSidebarToggleHidden = true
    private var sideBySideChatWidth: CGFloat = 0

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
            updateActivityWidth()
            if hidesItemsInPlace { setHidden(sidebarToggle, isVisible) } else { syncItemPresence() }
        }.store(in: &subscriptions)
    }

    /// Keeps the capsule over the terminal column while Chat is beside the
    /// terminal (0 when it is not), live as the divider moves.
    @MainActor
    func bind(sideBySideChatWidth: some Publisher<CGFloat, Never>) {
        sideBySideChatWidth.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] width in
            guard let self else { return }
            self.sideBySideChatWidth = width
            updateActivityWidth()
        }.store(in: &subscriptions)
    }

    /// Keeps the update pill's item in the toolbar exactly while an update
    /// state is showing and has room, and the capsule clear of it. Every
    /// state change is sent, not only visibility flips: the pill's text, so
    /// its width, changes with the state, and the capsule is sized from it.
    @MainActor
    func bind(updateVisible: some Publisher<Bool, Never>) {
        updateVisible.receive(on: DispatchQueue.main).sink { [weak self] isVisible in
            guard let self else { return }
            isUpdateShowing = isVisible
            updateActivityWidth()
            // SwiftUI lays the pill out for its new text after this turn.
            DispatchQueue.main.async { [weak self] in self?.updateActivityWidth() }
        }.store(in: &subscriptions)
    }

    /// Keeps the reset-zoom button in the toolbar exactly while a split is
    /// zoomed (it used to be a titlebar accessory, which hangs under the
    /// unified toolbar, off its row), and the capsule clear of it.
    @MainActor
    func bind(surfaceZoomed: some Publisher<Bool, Never>) {
        surfaceZoomed.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] isZoomed in
            guard let self else { return }
            isSurfaceZoomed = isZoomed
            updateActivityWidth()
        }.store(in: &subscriptions)
    }

    /// The split view is in the window: the tracking separator can join.
    @MainActor
    func attach(splitView: NSSplitView) {
        guard self.splitView == nil, let toolbar else { return }
        self.splitView = splitView
        if let window { observeLayout(of: window, splitView: splitView) }
        updateActivityWidth()
        let toggleCount = toolbar.items.contains { $0.itemIdentifier == .leoSidebarToggle } ? 1 : 0
        toolbar.insertItem(withItemIdentifier: .leoSplitSeparator, at: min(toggleCount, toolbar.items.count))
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemOrder.filter { $0 != .leoSplitSeparator && isPresentByDefault($0) }
    }

    /// Below macOS 15 `NSToolbarItem.isHidden` does nothing, so the items
    /// that come and go are added to and removed from the toolbar instead.
    private func isPresentByDefault(_ identifier: NSToolbarItem.Identifier) -> Bool {
        if hidesItemsInPlace { return true }
        switch identifier {
        case .leoSidebarToggle: return !isSidebarToggleHidden
        case .leoResetZoom: return isSurfaceZoomed
        case .leoUpdate: return isUpdateShowing && showsUpdateItem
        case .leoMore: return showsMoreItem
        default: return true
        }
    }

    /// Inserts or removes the sidebar toggle and the "⋯" item to match the
    /// bindings (macOS 14 and earlier).
    private func syncItemPresence() {
        guard let toolbar else { return }
        setPresence(of: .leoSidebarToggle, !isSidebarToggleHidden, in: toolbar) { _ in 0 }
        setPresence(of: .leoUpdate, isUpdateShowing && showsUpdateItem, in: toolbar) { toolbar in
            toolbar.items.firstIndex { $0.itemIdentifier == .leoMore } ?? toolbar.items.count
        }
        setPresence(of: .leoResetZoom, isSurfaceZoomed, in: toolbar) { toolbar in
            toolbar.items.firstIndex { [.leoUpdate, .leoMore].contains($0.itemIdentifier) } ?? toolbar.items.count
        }
        setPresence(of: .leoMore, showsMoreItem, in: toolbar) { $0.items.count }
    }

    private func setPresence(
        of identifier: NSToolbarItem.Identifier, _ isPresent: Bool, in toolbar: NSToolbar, at index: (NSToolbar) -> Int
    ) {
        let current = toolbar.items.firstIndex { $0.itemIdentifier == identifier }
        switch (isPresent, current) {
        case (true, nil): toolbar.insertItem(withItemIdentifier: identifier, at: index(toolbar))
        case (false, let position?): toolbar.removeItem(at: position)
        default: break
        }
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
        case .leoResetZoom: makeResetZoomItem()
        case .leoUpdate: makeUpdateItem()
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
        setHidden(item, isSidebarToggleHidden)
        return item
    }

    private var activityWidth: NSLayoutConstraint?
    private var activityContainerWidth: NSLayoutConstraint?
    private var layoutObservers: [NSObjectProtocol] = []

    private func makeActivityItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .leoActivity)
        let host = makeActivityView()
        host.translatesAutoresizingMaskIntoConstraints = false
        // AppKit centres the item's view in the region right of the sidebar.
        // The capsule leads a container that is wider by the offset (see
        // `LeoActivityCapsuleSizing.placement`), which moves the capsule's
        // centre left, over the terminal column, while Chat is beside it.
        let container = LeoActivityCapsuleContainer()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        let width = host.widthAnchor.constraint(equalToConstant: LeoActivityCapsulePresentation.maxWidth)
        let containerWidth = container.widthAnchor.constraint(equalToConstant: LeoActivityCapsulePresentation.maxWidth)
        activityWidth = width
        activityContainerWidth = containerWidth
        NSLayoutConstraint.activate([
            width, containerWidth,
            host.heightAnchor.constraint(equalToConstant: LeoActivityCapsule.height),
            container.heightAnchor.constraint(equalToConstant: LeoActivityCapsule.height),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        item.view = container
        // The capsule draws its own 32 pt glass: AppKit's platter is a fixed 36 pt.
        item.isBordered = false
        item.visibilityPriority = .high
        item.label = "Activity"
        activityItem = item
        updateActivityWidth()
        return item
    }

    /// Sizes the capsule from the room right of the sidebar
    /// (`LeoActivityCapsuleSizing`); on every window or split resize.
    private func updateActivityWidth() {
        guard let activityWidth, let activityContainerWidth, let window else { return }
        let sidebar = splitView?.arrangedSubviews.first.map { $0.isHidden ? 0 : $0.frame.maxX } ?? 0
        let leadingChrome = isSidebarToggleHidden ? 0 : LeoActivityCapsuleSizing.collapsedSidebarChrome
        let placement = LeoActivityCapsuleSizing.placement(
            windowWidth: window.frame.width, sidebarWidth: sidebar, chatLeadingEdge: chatLeadingEdge(in: window),
            leadingChrome: leadingChrome,
            trailingReserve: (isUpdateShowing ? updateReserve() : 0) + (isSurfaceZoomed ? Self.resetZoomReserve : 0))
        let layout = placement.layout
        let width = layout.width
        let containerWidth = width + placement.trailingPad
        if activityWidth.constant != width { activityWidth.constant = width }
        if activityContainerWidth.constant != containerWidth { activityContainerWidth.constant = containerWidth }
        showsMoreItem = layout.showsMoreItem
        showsUpdateItem = layout.showsUpdateItem
        if hidesItemsInPlace {
            setHidden(moreItem, !showsMoreItem)
            setHidden(updateItem, !(isUpdateShowing && showsUpdateItem))
            setHidden(resetZoomItem, !isSurfaceZoomed)
        } else {
            syncItemPresence()
        }
        let titleVisibility: NSWindow.TitleVisibility = layout.showsTitle ? .visible : .hidden
        if window.titleVisibility != titleVisibility { window.titleVisibility = titleVisibility }
        if showsSubtitle != layout.showsSubtitle {
            showsSubtitle = layout.showsSubtitle
            onSubtitleVisibilityChange()
        }
    }

    /// What the pill takes right of the capsule: its measured width (it
    /// changes with the update state's text) and the toolbar's spacing.
    private func updateReserve() -> CGFloat {
        let measured = updateItem?.view?.fittingSize.width ?? 0
        return (measured > 0 ? measured : LeoActivityCapsuleSizing.updateFallbackReserve) + Self.updateItemSpacing
    }

    /// `isHidden` where it takes effect; the callers insert and remove otherwise.
    private func setHidden(_ item: NSToolbarItem?, _ isHidden: Bool) {
        guard hidesItemsInPlace, let item else { return }
        if #available(macOS 15.0, *) { item.isHidden = isHidden }
    }

    /// Where the chat pane starts while it is beside the terminal: its width
    /// back from the detail column's trailing edge.
    private func chatLeadingEdge(in window: NSWindow) -> CGFloat? {
        guard sideBySideChatWidth > 0 else { return nil }
        let detailMaxX = splitView.flatMap { $0.arrangedSubviews.dropFirst().first?.frame.maxX } ?? window.frame.width
        return detailMaxX - sideBySideChatWidth
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

    /// The reset-zoom button, left of the update pill: shown only while a
    /// split is zoomed. Sent down the responder chain to the window's
    /// controller, like the sidebar toggle.
    private func makeResetZoomItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .leoResetZoom)
        item.image = NSImage(named: "ResetZoom")
            ?? NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Reset Split Zoom")
        item.label = "Reset Zoom"
        item.toolTip = "Reset Split Zoom"
        item.target = nil
        item.action = #selector(TerminalController.splitZoom(_:))
        item.isBordered = true
        item.visibilityPriority = .high
        setHidden(item, !isSurfaceZoomed)
        resetZoomItem = item
        return item
    }

    /// The update pill, left of "⋯". It sizes itself (the pill's text is
    /// fixed-width per state) and is hidden while no update state shows.
    private func makeUpdateItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .leoUpdate)
        item.view = makeUpdateView()
        // The pill draws its own capsule.
        item.isBordered = false
        item.visibilityPriority = .high
        item.label = "Update"
        setHidden(item, !(isUpdateShowing && showsUpdateItem))
        updateItem = item
        return item
    }

    private func makeMorePlaceholder() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .leoMore)
        item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        item.label = "More"
        item.menu = moreMenu
        item.showsIndicator = false
        // The first to fold into the overflow chevron when the window is narrow.
        item.visibilityPriority = .low
        setHidden(item, !showsMoreItem)
        moreItem = item
        return item
    }
}

/// The capsule's container: only the capsule takes clicks, and the empty
/// room beside it drags the window like the rest of the toolbar.
private final class LeoActivityCapsuleContainer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
