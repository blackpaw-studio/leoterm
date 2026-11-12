import AppKit
import Combine
import LeoKit

/// The agent pane: the 30 pt tab bar, and under it, while the drawer is open,
/// the selected tab's body. It draws what `LeoAgentPaneModel` says and sends
/// taps back; each plugin's summary and body are `LeoPluginSlotHostView`s on
/// the agent's pane slots, which report their visibility themselves.
@MainActor final class LeoAgentPaneViewController: NSViewController {
    private let model: LeoAgentPaneModel
    private let tabBar = LeoAgentPaneTabBarView()
    private let bodyContainer = NSView()
    private var bodyHost: LeoPluginSlotHostView?
    private var terminalBody: LeoDrawerTerminalBodyView?
    private var lastDrawer: LeoAgentPaneFocus.Drawer?
    private var occlusionObserver: NSObjectProtocol?
    private var bodyMount: LeoAgentPaneMount?
    private var summaryMounts: [String: LeoAgentPaneMount] = [:]
    private var tabViews: [String: LeoAgentPaneTabView] = [:]
    private var subscription: AnyCancellable?

    init(model: LeoAgentPaneModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// The tabs as drawn now (for tests and the visual check).
    var shownTabs: [LeoAgentPaneTab] { tabBar.tabViews.map(\.tab) }
    var isBodyShown: Bool { (bodyHost != nil || terminalBody != nil) && !bodyContainer.isHidden }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    override func loadView() {
        let root = LeoAgentPaneRootView()
        root.onWindowChange = { [weak self] in self?.windowChanged() }
        root.setAccessibilityLabel("Agent pane")
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar)
        root.addSubview(bodyContainer)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: LeoAgentPaneState.collapsedHeight),
            bodyContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        tabBar.onTapTab = { [weak self] in self?.model.tapTab($0) }
        tabBar.onToggle = { [weak self] in self?.model.toggle() }
        view = root
        sync()
        // `objectWillChange` fires before the change lands; the hop reads the new state.
        subscription = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sync() }
    }

    // MARK: Sync

    private func sync() {
        let mounts = model.mounts
        let drawer = LeoAgentPaneFocus.Drawer(
            isExpanded: model.isExpanded, selectedIsTerminal: model.selectedTabID == LeoAgentPaneTab.terminalID)
        // Read before the body is replaced: who held the keyboard, and whether the
        // terminal on screen is about to be another agent's.
        let hadFocus = terminalBody?.hasFocus ?? false
        syncTabs(summaries: mounts.summaries)
        let replacedTerminal = syncBody(mounts.body)
        bodyContainer.isHidden = !model.isExpanded
        moveFocus(from: lastDrawer ?? drawer, to: drawer, hadFocus: hadFocus, replacedTerminal: replacedTerminal)
        lastDrawer = drawer
        updateOcclusion()
    }

    private func moveFocus(from: LeoAgentPaneFocus.Drawer, to: LeoAgentPaneFocus.Drawer, hadFocus: Bool, replacedTerminal: Bool) {
        switch LeoAgentPaneFocus.transition(from: from, to: to, drawerHasFocus: hadFocus) {
        case .focusDrawer: terminalBody?.focusTerminal()
        case .focusMain: model.drawer?.focusMain()
        case .none:
            // Another agent's Terminal took the place of the one the keyboard was in.
            if hadFocus, replacedTerminal { terminalBody?.focusTerminal() }
        }
    }

    // MARK: Occlusion

    /// The drawer terminal draws only while it is on screen: a hidden
    /// libghostty surface keeps rendering otherwise, and drawer surfaces are in
    /// no controller's tree for the window's own occlusion sync to reach.
    private func updateOcclusion() {
        let windowVisible = view.window?.occlusionState.contains(.visible) ?? false
        terminalBody?.setOnScreen(LeoDrawerOcclusion.isVisible(
            isMounted: terminalBody?.window != nil, windowVisible: windowVisible, expanded: model.isExpanded,
            selectedIsTerminal: model.selectedTabID == LeoAgentPaneTab.terminalID))
    }

    private func windowChanged() {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window = view.window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateOcclusion() } }
        updateOcclusion()
    }

    private func syncTabs(summaries: [LeoAgentPaneMount]) {
        var next: [String: LeoAgentPaneTabView] = [:]
        for (tab, mount) in zip(model.tabs, summaries) {
            // A tab view is kept while its tab and its mount (the agent) are the same.
            if let existing = tabViews[tab.id], existing.tab == tab, summaryMounts[tab.id] == mount {
                next[tab.id] = existing
                continue
            }
            next[tab.id] = LeoAgentPaneTabView(tab: tab, summary: summaryHost(for: mount))
        }
        tabViews = next
        summaryMounts = Dictionary(uniqueKeysWithValues: zip(model.tabs.map(\.id), summaries))
        tabBar.setTabs(model.tabs.compactMap { next[$0.id] }, selected: model.selectedTabID, isExpanded: model.isExpanded)
    }

    private func summaryHost(for mount: LeoAgentPaneMount) -> (any LeoAgentPaneSummaryView)? {
        switch mount {
        case .plugin(let key):
            guard let surfaces = model.surfaces else { return nil }
            let host = LeoPluginSlotHostView(key: key, surface: surfaces, style: .summary)
            host.onContentChange = { [weak self] _ in self?.tabBar.needsLayout = true }
            return host
        case .terminal(let identity):
            guard let drawer = model.drawer else { return nil }
            let summary = LeoDrawerSummaryView(identity: identity, environment: drawer)
            summary.onChange = { [weak self] in self?.tabBar.needsLayout = true }
            return summary
        }
    }

    /// Mounts `mount` as the body. Returns whether a Terminal body replaced another one.
    @discardableResult
    private func syncBody(_ mount: LeoAgentPaneMount?) -> Bool {
        guard mount != bodyMount else { return false }
        bodyMount = mount
        bodyHost?.removeFromSuperview()
        bodyHost = nil
        let hadTerminal = terminalBody != nil
        unmountTerminal()
        if case .terminal(let identity) = mount, let drawer = model.drawer {
            mountTerminal(identity: identity, drawer: drawer)
            return hadTerminal
        }
        guard let key = mount?.pluginKey, let surfaces = model.surfaces else { return false }
        let host = LeoPluginSlotHostView(key: key, surface: surfaces)
        host.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            host.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
        ])
        bodyHost = host
        return false
    }

    private func mountTerminal(identity: LeoAgentIdentity, drawer: LeoDrawerEnvironment) {
        let body = LeoDrawerTerminalBodyView(identity: identity, environment: drawer)
        body.translatesAutoresizingMaskIntoConstraints = false
        // ⌘W with the drawer focused collapses it (it would otherwise close the main surface).
        body.onCloseRequested = { [weak self] in self?.model.toggle() }
        bodyContainer.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            body.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
        ])
        terminalBody = body
        body.start()
    }

    private func unmountTerminal() {
        terminalBody?.stop()
        terminalBody?.removeFromSuperview()
        terminalBody = nil
    }
}

/// The pane's background: the window's own, so it reads as part of the chrome
/// rather than the terminal.
private final class LeoAgentPaneRootView: NSView {
    var onWindowChange: () -> Void = {}
    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange()
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
