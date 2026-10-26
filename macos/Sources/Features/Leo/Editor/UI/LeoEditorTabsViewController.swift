import AppKit
import Combine

/// A row's editor pane (B-273): its tabs, each with its own
/// `LeoEditorPaneViewController` (so undo, scroll and selection survive a
/// switch), and the tab strip once there are two or more. It collapses
/// its split item while no tab is open and expands it when one opens, but
/// takes focus only when the user asked (`LeoEditorTabs.focusRequest`): a
/// file opened in the background leaves focus where it is. When the tab
/// with focus goes, focus moves to the newly selected tab, or back to the
/// terminal once the last one closes.
///
/// While the row's agent has a browser (`rowPane.agentBrowser`), the strip
/// starts with a Browser item and the pane can show the browser
/// (`LeoAgentBrowserPaneViewController`) instead of the selected tab. The
/// browser appearing opens the pane like a background open: no focus taken.
final class LeoEditorTabsViewController: NSViewController {
    let tabs: LeoEditorTabs
    let tabBar = LeoEditorTabBar()
    /// The selected tab's view, once there is one.
    private(set) var shown: LeoEditorPaneViewController?
    /// The agent browser's view, while it is the pane's content.
    private(set) var shownBrowser: LeoAgentBrowserPaneViewController?
    private let rowPane: LeoRowPane?
    private let headerTopInset: CGFloat?
    private var tabViews: [ObjectIdentifier: LeoEditorPaneViewController] = [:]
    private var browserViews: [ObjectIdentifier: LeoAgentBrowserPaneViewController] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var documentSubscriptions: Set<AnyCancellable> = []

    /// Binds right away, as the pane view does: a collapsed split item's
    /// view isn't loaded until it is shown.
    init(tabs: LeoEditorTabs, rowPane: LeoRowPane? = nil, headerTopInset: CGFloat? = nil) {
        self.tabs = tabs
        self.rowPane = rowPane
        self.headerTopInset = headerTopInset
        super.init(nibName: nil, bundle: nil)
        tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        bind()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        view.setAccessibilityElement(false)
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: LeoEditorPaneViewController.minimumWidth).isActive = true
        if let shownBrowser { embed(shownBrowser) } else if let shown { embed(shown) }
    }

    /// Whether focus is in the pane.
    var hasFocus: Bool { shown?.hasFocus ?? false }

    /// Focuses the selected tab's text.
    func focusText() {
        shown?.focusText()
    }

    /// The view of `tab`, made the first time it's asked for.
    func view(for tab: LeoEditorPaneModel) -> LeoEditorPaneViewController {
        let id = ObjectIdentifier(tab)
        if let view = tabViews[id] { return view }
        let view = LeoEditorPaneViewController(model: tab, headerTopInset: headerTopInset)
        view.recents = { [weak tabs] in tabs?.recents ?? [] }
        view.onSelectRecent = { [weak self] fileID in self?.openRecent(fileID) }
        view.onCloseRequest = { [weak self, weak tab] in
            guard let self, let tab else { return }
            close(tab)
        }
        tabViews[id] = view
        return view
    }

    // MARK: - Binding

    private func bind() {
        tabs.$tabs.map { _ in () }
            .merge(with: tabs.$selected.map { _ in () }, tabs.$recents.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
        tabs.$focusRequest.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // The user asked for a file: it comes in front of the browser.
                self?.rowPane?.showEditor()
                self?.refresh()
                self?.focusText()
            }
            .store(in: &subscriptions)
        rowPane?.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
    }

    private var showsBrowser: Bool { rowPane?.content == .agentBrowser }

    /// The browser's view, made the first time it's asked for.
    private func browserView(for source: any LeoAgentBrowserPaneSource) -> LeoAgentBrowserPaneViewController {
        let id = ObjectIdentifier(source)
        if let view = browserViews[id] { return view }
        let view = LeoAgentBrowserPaneViewController(source: source, headerTopInset: headerTopInset)
        view.onCloseBrowser = { [weak self] in self?.rowPane?.closeAgentBrowser() }
        browserViews[id] = view
        return view
    }

    /// Catches the views up with the tabs as they are now.
    private func refresh() {
        let current = tabs.tabs
        let live = Set(current.map(ObjectIdentifier.init))
        tabViews = tabViews.filter { live.contains($0.key) }
        let browserSource = rowPane?.agentBrowser
        let liveBrowsers = browserSource.map { [ObjectIdentifier($0)] } ?? []
        browserViews = browserViews.filter { liveBrowsers.contains($0.key) }
        let nextBrowser = showsBrowser ? browserSource.map(browserView(for:)) : nil
        let next = showsBrowser ? nil : tabs.selected.map(view(for:))
        if next !== shown || nextBrowser !== shownBrowser { swap(to: next, browser: nextBrowser) }
        shown?.refreshChrome()
        observeDocuments(of: current)
        refreshStrip()
        setLeoSplitItemCollapsed(!isPaneOpen, openingAtHalfWidth: true)
    }

    private func observeDocuments(of current: [LeoEditorPaneModel]) {
        documentSubscriptions = Set(current.compactMap { tab in
            tab.document?.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.refreshStrip() }
        })
    }

    private func refreshStrip() {
        let selected = showsBrowser ? nil : tabs.selected
        let files = tabs.tabs.compactMap { tab -> LeoEditorTabBar.Item? in
            guard let fileID = tab.document?.fileID else { return nil }
            return LeoEditorTabBar.Item(
                title: LeoEditorHeaderView.title(for: fileID), toolTip: LeoEditorHeaderView.location(of: fileID),
                isDirty: tab.document?.isDirty == true, isSelected: tab === selected
            )
        }
        let browser = hasBrowserItem
            ? [LeoEditorTabBar.Item(title: "Browser", toolTip: "Agent browser", isDirty: false, isSelected: showsBrowser, isBrowser: true)]
            : []
        let items = browser + files
        tabBar.update(items)
        tabBar.isHidden = items.count < 2
    }

    // MARK: - Switching

    private func swap(to next: LeoEditorPaneViewController?, browser nextBrowser: LeoAgentBrowserPaneViewController?) {
        let hadFocus = hasFocus
        let window = isViewLoaded ? view.window : nil
        if let shown {
            if shown.isViewLoaded { shown.view.removeFromSuperview() }
            shown.removeFromParent()
        }
        if let shownBrowser {
            if shownBrowser.isViewLoaded { shownBrowser.view.removeFromSuperview() }
            shownBrowser.removeFromParent()
        }
        shown = next
        shownBrowser = nextBrowser
        if let nextBrowser {
            addChild(nextBrowser)
            // Focus that was in a text tab goes to the terminal, as when its tab closes.
            if hadFocus { focusTerminal(in: window) }
            if isViewLoaded { embed(nextBrowser) }
            return
        }
        guard let next else {
            if hadFocus { focusTerminal(in: window) }
            return
        }
        addChild(next)
        guard isViewLoaded else { return }
        embed(next)
        next.onShown()
        if hadFocus { next.focusText() }
    }

    private func embed(_ browser: LeoAgentBrowserPaneViewController) {
        let paneView = browser.view
        browser.install(tabBar: tabBar)
        paneView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneView.topAnchor.constraint(equalTo: view.topAnchor),
            paneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func embed(_ pane: LeoEditorPaneViewController) {
        let paneView = pane.view
        pane.install(tabBar: tabBar)
        paneView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneView.topAnchor.constraint(equalTo: view.topAnchor),
            paneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Actions

    /// Close Editor Tab: the selected tab, as its close button does.
    func closeSelectedTab() {
        if showsBrowser {
            rowPane?.closeAgentBrowser()
            return
        }
        guard let selected = tabs.selected else { return }
        close(selected)
    }

    private var hasBrowserItem: Bool { rowPane?.isAgentBrowserOpen == true }

    /// The strip's index for a file tab: the Browser item, when there is one, comes first.
    private var fileIndexOffset: Int { hasBrowserItem ? 1 : 0 }

    private func selectTab(at index: Int) {
        if hasBrowserItem, index == 0 {
            rowPane?.showAgentBrowser()
            return
        }
        let index = index - fileIndexOffset
        guard tabs.tabs.indices.contains(index) else { return }
        rowPane?.showEditor()
        tabs.select(tabs.tabs[index])
    }

    private func closeTab(at index: Int) {
        if hasBrowserItem, index == 0 {
            rowPane?.closeAgentBrowser()
            return
        }
        let index = index - fileIndexOffset
        guard tabs.tabs.indices.contains(index) else { return }
        close(tabs.tabs[index])
    }

    /// The header's close button and ⌘W close the tab (asking first when
    /// it has unsaved edits); closing the last one gives focus back to the
    /// terminal beside the pane.
    private func close(_ tab: LeoEditorPaneModel) {
        let window = view.window
        Task { [weak self] in
            guard let self, await tabs.closeTab(tab), !tabs.isOpen else { return }
            focusTerminal(in: window)
        }
    }

    private func openRecent(_ fileID: LeoEditorFileID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await tabs.open(fileID)
            } catch {
                LeoEditorAlerts.presentError(error, on: view.window)
            }
            // A failed open leaves the pop-up on the open file.
            shown?.refreshChrome()
        }
    }

    private func focusTerminal(in window: NSWindow?) {
        guard let controller = window?.windowController as? BaseTerminalController, let surface = controller.focusedSurface else { return }
        Ghostty.moveFocus(to: surface)
    }
}

extension LeoEditorTabsViewController: LeoRowPaneChild {
    var isPaneOpen: Bool { tabs.isOpen || hasBrowserItem }

    /// Back on screen (B-274): the selected tab's file may have changed.
    func onShown() {
        shown?.onShown()
    }
}
