import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// The Chats inbox: every thread across paired daemons, the ones that need
/// you first, with filter chips and search. "New chat" picks any agent.
final class ChatsViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    @UIBindable private var store: StoreOf<AppFeature>
    private var rows: [ChatRow] = []
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, AgentRef>!
    private weak var filterBar: ChatFilterBar?
    private var selectedFilter = ChatFilter.all
    private var counts = ChatCounts(needsYou: 0, working: 0)
    private let searchController = UISearchController(searchResultsController: nil)

    init(store: StoreOf<AppFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Chats")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        let newChat = UIBarButtonItem(
            image: UIImage(systemName: "square.and.pencil"),
            primaryAction: UIAction { [weak self] _ in self?.store.send(.chats(.newChatButtonTapped)) }
        )
        newChat.accessibilityLabel = String(localized: "New Chat")
        navigationItem.rightBarButtonItem = newChat

        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = String(localized: "Search chats")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "chats.list"
        collectionView.keyboardDismissMode = .onDrag
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            store.send(.chats(.refresh(store.fleet.sessions.map(\.daemon))))
            refresh.endRefreshing()
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
        configureDataSource()

        present(isPresented: $store.chats.isShowingNewChat) { [store] in
            UINavigationController(rootViewController: NewChatViewController(store: store))
        }

        observe { [weak self] in
            guard let self else { return }
            let all = ChatList.rows(threads: store.chats.threads, unread: store.chats.unreadCounts, sessions: store.fleet.sessions)
            let filter = store.chats.filter ?? .all
            let search = store.chats.searchText
            render(
                all: all, visible: ChatList.visible(all, filter: filter, search: search), filter: filter, search: search,
                selection: store.chat?.ref, hasDaemons: !store.fleet.sessions.isEmpty
            )
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if splitViewController?.isCollapsed == true, let selected = collectionView.indexPathsForSelectedItems?.first {
            collectionView.deselectItem(at: selected, animated: animated)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != store.chats.searchText else { return }
        store.send(.chats(.binding(.set(\.searchText, text))))
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, AgentRef> { [weak self] cell, _, ref in
            guard let row = self?.rows.first(where: { $0.ref == ref }) else { return }
            let configuration = ChatInboxConfiguration(row: row)
            cell.contentConfiguration = configuration
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "chat.\(row.ref.name)"
            cell.accessibilityLabel = configuration.accessibilityText
        }
        let header = UICollectionView.SupplementaryRegistration<ChatFilterBar>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] bar, _, _ in
            guard let self else { return }
            filterBar = bar
            bar.onPick = { [weak self] filter in self?.store.send(.chats(.filterPicked(filter))) }
            bar.update(selected: selectedFilter, counts: counts)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, ref in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: ref)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func render(all: [ChatRow], visible: [ChatRow], filter: ChatFilter, search: String, selection: AgentRef?, hasDaemons: Bool) {
        let previous = rows
        rows = visible
        selectedFilter = filter
        counts = ChatList.counts(all)
        filterBar?.update(selected: filter, counts: counts)
        var snapshot = NSDiffableDataSourceSnapshot<Int, AgentRef>()
        snapshot.appendSections([0])
        snapshot.appendItems(visible.map(\.ref))
        let changed = visible.filter { row in previous.first { $0.ref == row.ref } != row }.map(\.ref)
        snapshot.reconfigureItems(changed.filter { snapshot.itemIdentifiers.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: !previous.isEmpty)
        if let selection, splitViewController?.isCollapsed == false, let indexPath = dataSource.indexPath(for: selection) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
        contentUnavailableConfiguration = visible.isEmpty ? emptyState(filter: filter, search: search, hasChats: !all.isEmpty, hasDaemons: hasDaemons) : nil
    }

    private func emptyState(filter: ChatFilter, search: String, hasChats: Bool, hasDaemons: Bool) -> UIContentUnavailableConfiguration {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .search() }
        var configuration = UIContentUnavailableConfiguration.empty()
        if filter != .all, hasChats {
            let (symbol, text) = switch filter {
            case .needsYou: ("checkmark.circle", String(localized: "Nothing Needs You"))
            case .working: ("moon.zzz", String(localized: "Nothing Is Working"))
            case .done, .all: ("tray", String(localized: "Nothing Done Yet"))
            }
            configuration.image = UIImage(systemName: symbol)
            configuration.text = text
            var button = UIButton.Configuration.borderedTinted()
            button.title = String(localized: "All Chats")
            configuration.button = button
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.store.send(.chats(.filterPicked(.all))) }
            configuration.buttonProperties.primaryAction?.accessibilityLabel = String(localized: "All Chats")
            return configuration
        }
        configuration.image = UIImage(systemName: "bubble.left.and.bubble.right")
        configuration.text = String(localized: "No Chats")
        if hasDaemons {
            configuration.secondaryText = String(localized: "Start a chat with any agent on your paired daemons.")
        } else {
            configuration.secondaryText = String(localized: "Pair a machine to chat with its agents.")
            var button = UIButton.Configuration.borderedTinted()
            button.title = String(localized: "Pair a Machine")
            configuration.button = button
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.store.send(.pairButtonTapped) }
        }
        return configuration
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let ref = dataSource.itemIdentifier(for: indexPath) else { return }
        store.send(.chats(.rowTapped(ref)))
    }
}

/// The chip row above the inbox: All, Needs you, Working, Done.
final class ChatFilterBar: UICollectionReusableView {
    var onPick: (ChatFilter) -> Void = { _ in }
    private var buttons: [ChatFilter: UIButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        for filter in ChatFilter.allCases {
            let button = UIButton(primaryAction: UIAction { [weak self] _ in self?.onPick(filter) })
            button.accessibilityIdentifier = "chats.filter.\(filter.identifier)"
            buttons[filter] = button
            stack.addArrangedSubview(button)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: 0),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(selected: ChatFilter, counts: ChatCounts) {
        for (filter, button) in buttons {
            var configuration = filter == selected ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            configuration.cornerStyle = .capsule
            configuration.title = filter.title(counts: counts)
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            button.configuration = configuration
            button.isSelected = filter == selected
            button.accessibilityTraits = filter == selected ? [.button, .selected] : .button
        }
    }
}

private extension ChatFilter {
    var identifier: String {
        switch self {
        case .all: "all"
        case .needsYou: "needsYou"
        case .working: "working"
        case .done: "done"
        }
    }

    func title(counts: ChatCounts) -> String {
        switch self {
        case .all: String(localized: "All")
        case .needsYou: counts.needsYou > 0 ? String(localized: "Needs you (\(counts.needsYou))") : String(localized: "Needs you")
        case .working: counts.working > 0 ? String(localized: "Working (\(counts.working))") : String(localized: "Working")
        case .done: String(localized: "Done")
        }
    }
}

/// The "New chat" sheet: every agent on every paired daemon.
final class NewChatViewController: UIViewController, UICollectionViewDelegate {
    private let store: StoreOf<AppFeature>
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<String, AgentRef>!
    private var sections: [AgentSection] = []

    init(store: StoreOf<AppFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "New Chat")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.store.send(.chats(.binding(.set(\.isShowingNewChat, false))))
        })
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, AgentRef> { [weak self] cell, _, ref in
            guard let agent = self?.sections.first(where: { $0.id == ref.daemonID })?.agents.first(where: { $0.name == ref.name }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = agent.name
            cell.accessibilityIdentifier = "newChat.\(agent.name)"
            content.secondaryText = agent.statusText
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: agent.badge.symbol)
            content.imageProperties.tintColor = agent.badge.tint
            cell.contentConfiguration = content
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.sections[safe: indexPath.section]?.daemon.name
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, ref in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: ref)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        observe { [weak self] in
            guard let self else { return }
            sections = store.fleet.sections
            var snapshot = NSDiffableDataSourceSnapshot<String, AgentRef>()
            for section in sections {
                snapshot.appendSections([section.id])
                let names = section.agents.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                snapshot.appendItems(names.map { AgentRef(daemonID: section.id, name: $0) }, toSection: section.id)
            }
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let ref = dataSource.itemIdentifier(for: indexPath) else { return }
        store.send(.chats(.newChatPicked(ref)))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
