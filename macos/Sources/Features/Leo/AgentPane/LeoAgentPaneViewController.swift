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
    var isBodyShown: Bool { bodyHost != nil && !bodyContainer.isHidden }

    override func loadView() {
        let root = LeoAgentPaneRootView()
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
        syncTabs(summaries: mounts.summaries)
        syncBody(mounts.body)
        bodyContainer.isHidden = !model.isExpanded
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

    private func summaryHost(for mount: LeoAgentPaneMount) -> LeoPluginSlotHostView? {
        guard let key = mount.pluginKey, let surfaces = model.surfaces else { return nil }
        let host = LeoPluginSlotHostView(key: key, surface: surfaces, style: .summary)
        host.onContentChange = { [weak self] _ in self?.tabBar.needsLayout = true }
        return host
    }

    private func syncBody(_ mount: LeoAgentPaneMount?) {
        guard mount != bodyMount else { return }
        bodyMount = mount
        bodyHost?.removeFromSuperview()
        bodyHost = nil
        guard let key = mount?.pluginKey, let surfaces = model.surfaces else { return }
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
    }
}

/// The pane's background: the window's own, so it reads as part of the chrome
/// rather than the terminal.
private final class LeoAgentPaneRootView: NSView {
    override var wantsUpdateLayer: Bool { true }

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
