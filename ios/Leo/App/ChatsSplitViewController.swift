import ComposableArchitecture
import LeoFeatures
import UIKit

/// The Chats tab: the inbox beside the open thread.
final class ChatsSplitViewController: SelectionSplitViewController {
    private let store: StoreOf<AppFeature>
    private let panel = TaskPanelView()
    fileprivate static let compactPanelGap: CGFloat = 8
    fileprivate var panelRegularConstraints: [NSLayoutConstraint] = []
    fileprivate var panelCompactConstraints: [NSLayoutConstraint] = []
    fileprivate lazy var panelCompactFallbackTop = panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52)
    fileprivate var panelCompactNavigationTop: NSLayoutConstraint?

    init(store: StoreOf<AppFeature>) {
        self.store = store
        super.init(
            primary: ChatsViewController(store: store),
            placeholder: { NoSelectionViewController(.chat) },
            makeScreen: { _ in store.scope(state: \.chat, action: \.chat).map(ChatThreadViewController.init(store:)) },
            selectionPopped: { store.send(.chatPopped) }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        anchorCompactPanelToNavigationBar()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        anchorCompactPanelToNavigationBar()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe { [weak self] in
            guard let self else { return }
            select(store.chat?.ref)
        }
        installTaskPanel()
    }
}

extension ChatsSplitViewController {
    /// Chat panel B: a card below the navigation bar over the list and the
    /// thread. Regular width: 320 pt, top-right. Compact width: the full width
    /// less a 16 pt inset, so titles do not truncate.
    private func installTaskPanel() {
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        view.addSubview(panel)
        let guide = view.safeAreaLayoutGuide
        let widthPreference = panel.widthAnchor.constraint(equalToConstant: 320)
        widthPreference.priority = .defaultHigh
        panelRegularConstraints = [
            panel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 52),
            panel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 12),
            widthPreference,
        ]
        // Until the bar is in the hierarchy (see `anchorCompactPanelToNavigationBar`) the card rides the safe area.
        panelCompactConstraints = [
            panelCompactFallbackTop,
            panel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
        ]
        syncPanelWidthClass()
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in self.syncPanelWidthClass() }
        panel.onToggle = { [store] in store.send(.fleet(.progressPanelToggled)) }
        panel.onOpen = { [store] ref in store.send(.chatOpened(ref)) }
        panel.onDismiss = { [store] row in store.send(.fleet(.dismissTask(row.ref.daemonID, agent: row.ref.name, id: row.task.id))) }
        observe { [weak self] in
            guard let self else { return }
            // An open thread shows only its own agent's tasks; the list shows the fleet's.
            let scope = store.chat?.ref
            let rows = store.fleet.taskPanelRows(scopedTo: scope)
            panel.render(
                header: store.fleet.taskPanelHeader(scopedTo: scope), rows: rows,
                isCollapsed: store.fleet.isProgressPanelCollapsed, now: store.fleet.progressClock
            )
            // Compact: the list and thread start below the collapsed card, so it never hides content.
            let reservesSpace = store.fleet.isCompactWidth && !rows.isEmpty
            topContentInset = reservesSpace ? Self.compactPanelGap * 2 + panel.collapsedHeight : 0
        }
    }

    /// Lays the card out for the current width class and tells the fleet, which
    /// owns the collapsed-by-default rule.
    private func syncPanelWidthClass() {
        let isCompact = traitCollection.horizontalSizeClass == .compact
        NSLayoutConstraint.deactivate(isCompact ? panelRegularConstraints : panelCompactConstraints)
        NSLayoutConstraint.activate(isCompact ? panelCompactConstraints : panelRegularConstraints)
        store.send(.fleet(.widthClassChanged(isCompact: isCompact)))
        anchorCompactPanelToNavigationBar()
    }

    /// The split view's own safe area stops above its child navigation bars, so the
    /// compact card hangs from the list's bar once that is in the hierarchy.
    func anchorCompactPanelToNavigationBar() {
        guard panelCompactNavigationTop == nil, primaryNavigationBar.isDescendant(of: view) else { return }
        let top = panel.topAnchor.constraint(equalTo: primaryNavigationBar.bottomAnchor, constant: Self.compactPanelGap)
        panelCompactNavigationTop = top
        panelCompactConstraints = panelCompactConstraints.filter { $0 !== panelCompactFallbackTop } + [top]
        panelCompactFallbackTop.isActive = false
        if traitCollection.horizontalSizeClass == .compact { top.isActive = true }
    }
}
