import ComposableArchitecture
import LeoFeatures
import UIKit

/// The Chats tab: the inbox beside the open thread.
final class ChatsSplitViewController: SelectionSplitViewController {
    private let store: StoreOf<AppFeature>
    private let panel = TaskPanelView()

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
    /// Chat panel B: docked top-right, below the navigation bar, over the list
    /// and the thread.
    private func installTaskPanel() {
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52),
            panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
        ])
        let widthPreference = panel.widthAnchor.constraint(equalToConstant: 320)
        widthPreference.priority = .defaultHigh
        widthPreference.isActive = true
        panel.onToggle = { [store] in store.send(.fleet(.progressPanelToggled)) }
        panel.onOpen = { [store] ref in store.send(.chatOpened(ref)) }
        panel.onDismiss = { [store] row in store.send(.fleet(.dismissTask(row.ref.daemonID, agent: row.ref.name, id: row.task.id))) }
        observe { [weak self] in
            guard let self else { return }
            panel.render(
                header: store.fleet.taskPanelHeader, rows: store.fleet.taskPanelRows,
                isCollapsed: store.fleet.isProgressPanelCollapsed, now: store.fleet.progressClock
            )
        }
    }
}
