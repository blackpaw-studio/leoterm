import AppKit
import Combine

extension NSToolbarItem.Identifier {
    static let leoSidebarToggle = NSToolbarItem.Identifier("leo.toolbar.sidebarToggle")
    static let leoSplitSeparator = NSToolbarItem.Identifier("leo.toolbar.splitSeparator")
    static let leoActivity = NSToolbarItem.Identifier("leo.toolbar.activity")
    static let leoUpdate = NSToolbarItem.Identifier("leo.toolbar.update")
    static let leoViewSwitch = NSToolbarItem.Identifier("leo.toolbar.viewSwitch")
    static let leoInterrupt = NSToolbarItem.Identifier("leo.toolbar.interrupt")
    static let leoMore = NSToolbarItem.Identifier("leo.toolbar.more")
}

/// The agent window's toolbar: the sidebar toggle (shown only while the
/// sidebar is collapsed), a tracking separator that keeps the title and the
/// items over the detail column, the activity capsule centred, and the
/// trailing groups: the Terminal | Chat switch, then Interrupt and a "⋯"
/// menu (one glass group). The trailing items are always present, at every
/// width (`LeoActivityCapsuleSizing.trailingGroupsReserve`).
///
/// The tracking separator needs the window's `NSSplitView`, which exists
/// only after SwiftUI's first layout, so the toolbar goes up at once (the
/// sidebar's inset needs its height) and the separator joins when the split
/// hands itself over (`attach(splitView:)`).
final class LeoAgentToolbar: NSObject, NSToolbarDelegate {
    /// The items in order once the split has been handed over.
    static let itemOrder: [NSToolbarItem.Identifier] = [
        .leoSidebarToggle, .leoSplitSeparator, .flexibleSpace, .leoActivity, .flexibleSpace, .leoUpdate,
        .leoViewSwitch, .leoInterrupt, .leoMore,
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
    /// The live main menu, where Interrupt's tooltip reads its shortcut (set
    /// before `install`).
    var mainMenu: () -> NSMenu? = { nil }
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
    private weak var updateItem: NSToolbarItem?
    private weak var viewSwitchControl: LeoToolbarViewSwitch?
    private weak var interruptItem: NSToolbarItem?
    private var interruptIsEnabled = false
    /// What the switch binding last said, so a switch AppKit builds later starts right.
    private var viewSwitchPresentation = LeoViewSwitchPresentation(layout: nil, unreadCount: 0)
    private var selectView: (LeoAgentViewChoice) -> Void = { _ in }
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

    /// Keeps the switch showing `presentation` and sends clicks to `select`.
    @MainActor
    func bind(viewSwitch: some Publisher<LeoViewSwitchPresentation, Never>, select: @escaping (LeoAgentViewChoice) -> Void) {
        selectView = select
        viewSwitchControl?.onSelect = select
        viewSwitch.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] presentation in
            guard let self else { return }
            viewSwitchPresentation = presentation
            viewSwitchControl?.apply(presentation)
        }.store(in: &subscriptions)
    }

    /// Keeps Interrupt enabled exactly while `isEnabled` says so. Pushed, not
    /// autovalidated: AppKit validates toolbar items on window events only,
    /// and an agent going idle is a model change. The caller feeds it the
    /// same availability rule as Agents ▸ Interrupt.
    @MainActor
    func bind(interruptEnabled isEnabled: some Publisher<Bool, Never>) {
        isEnabled.receive(on: DispatchQueue.main).sink { [weak self] isEnabled in
            guard let self else { return }
            interruptIsEnabled = isEnabled
            refreshInterruptTooltip()
            if interruptItem?.isEnabled != isEnabled { interruptItem?.isEnabled = isEnabled }
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
        case .leoUpdate: return isUpdateShowing && showsUpdateItem
        default: return true
        }
    }

    /// Inserts or removes the sidebar toggle and the update pill to match the
    /// bindings (macOS 14 and earlier).
    private func syncItemPresence() {
        guard let toolbar else { return }
        setPresence(of: .leoSidebarToggle, !isSidebarToggleHidden, in: toolbar) { _ in 0 }
        setPresence(of: .leoUpdate, isUpdateShowing && showsUpdateItem, in: toolbar) { toolbar in
            toolbar.items.firstIndex { $0.itemIdentifier == .leoViewSwitch } ?? toolbar.items.count
        }
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
        case .leoUpdate: makeUpdateItem()
        case .leoViewSwitch: makeViewSwitchItem()
        case .leoInterrupt: makeInterruptItem()
        case .leoMore: makeMoreItem()
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
    /// The trailing items never fold into the overflow chevron: `.user` is the
    /// toolbar's last-to-go priority. (`.high` makes the toolbar re-lay out
    /// against the capsule's width constraint as the sidebar resizes, which
    /// stalls the sidebar's own re-layout: `LeoSidebarTitlebarStyleTests`.)
    private static let trailingPriority = NSToolbarItem.VisibilityPriority.user

    private func updateActivityWidth() {
        guard let activityWidth, let activityContainerWidth, let window else { return }
        let sidebar = splitView?.arrangedSubviews.first.map { $0.isHidden ? 0 : $0.frame.maxX } ?? 0
        let leadingChrome = isSidebarToggleHidden ? 0 : LeoActivityCapsuleSizing.collapsedSidebarChrome
        let placement = LeoActivityCapsuleSizing.placement(
            windowWidth: window.frame.width, sidebarWidth: sidebar, chatLeadingEdge: chatLeadingEdge(in: window),
            leadingChrome: leadingChrome, trailingReserve: isUpdateShowing ? updateReserve() : 0)
        let layout = placement.layout
        let width = layout.width
        let containerWidth = width + placement.trailingPad
        if activityWidth.constant != width { activityWidth.constant = width }
        if activityContainerWidth.constant != containerWidth { activityContainerWidth.constant = containerWidth }
        showsUpdateItem = layout.showsUpdateItem
        if hidesItemsInPlace {
            setHidden(updateItem, !(isUpdateShowing && showsUpdateItem))
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

    /// The Terminal | Chat switch, in its own glass group. Never hidden.
    private func makeViewSwitchItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .leoViewSwitch)
        let control = MainActor.assumeIsolated {
            let control = LeoToolbarViewSwitch()
            control.onSelect = selectView
            control.apply(viewSwitchPresentation)
            return control
        }
        item.view = control
        item.label = LeoViewSwitchPresentation.groupLabel
        item.visibilityPriority = Self.trailingPriority
        viewSwitchControl = control
        return item
    }

    /// Interrupt, sharing one glass group with "⋯" (bordered items side by
    /// side). Always present, never hidden; `bind(interruptEnabled:)` enables
    /// it. The click goes down the responder chain like the menu item's.
    private func makeInterruptItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .leoInterrupt)
        item.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: Self.interruptTitle)
        item.label = Self.interruptTitle
        item.target = nil
        item.action = #selector(TerminalController.interruptSelectedLeoAgent(_:))
        item.isBordered = true
        item.visibilityPriority = Self.trailingPriority
        // Nothing to interrupt until the binding says so.
        item.autovalidates = false
        item.isEnabled = interruptIsEnabled
        interruptItem = item
        refreshInterruptTooltip()
        return item
    }

    private static let interruptTitle = "Interrupt"

    /// "Interrupt (⌃⌘.)": the shortcut is read from the live Agents menu, so
    /// a rebind never leaves the tooltip lying.
    private func refreshInterruptTooltip() {
        let shortcut = MainActor.assumeIsolated {
            LeoMenuShortcutHint.text(
                for: LeoMenuShortcutHint.menuItem(action: #selector(TerminalController.interruptSelectedLeoAgent(_:)), in: mainMenu()))
        }
        let tooltip = shortcut.map { "\(Self.interruptTitle) (\($0))" } ?? Self.interruptTitle
        if interruptItem?.toolTip != tooltip { interruptItem?.toolTip = tooltip }
    }

    private func makeMoreItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .leoMore)
        item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        item.label = "More"
        item.menu = moreMenu
        item.showsIndicator = false
        item.visibilityPriority = Self.trailingPriority
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
