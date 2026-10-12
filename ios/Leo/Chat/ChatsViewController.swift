import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// Leo Chat threads across paired daemons: pinned (assistant first), then
/// recent, then running agents with no thread yet. "New chat" picks any agent.
final class ChatsViewController: UIViewController, UICollectionViewDelegate {
    @UIBindable private var store: StoreOf<AppFeature>
    private var rows: [ChatRow] = []
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<ChatRow.Section, AgentRef>!

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

        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "chats.list"
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
            render(ChatList.rows(threads: store.chats.threads, sessions: store.fleet.sessions), selection: store.chat?.ref)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if splitViewController?.isCollapsed == true, let selected = collectionView.indexPathsForSelectedItems?.first {
            collectionView.deselectItem(at: selected, animated: animated)
        }
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
            cell.contentConfiguration = Self.content(for: row)
            var accessories: [UICellAccessory] = [.disclosureIndicator()]
            if row.unread > 0 {
                accessories.insert(.customView(configuration: .init(customView: BadgeView(text: "\(row.unread)", tint: .tintColor), placement: .trailing())), at: 0)
            }
            cell.accessories = accessories
            cell.accessibilityIdentifier = "chat.\(row.ref.name)"
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .pinned: String(localized: "Pinned")
            case .recent: String(localized: "Recent")
            case .running: String(localized: "Running")
            case nil: nil
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, ref in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: ref)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private static func content(for row: ChatRow) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.image = UIImage(systemName: row.ref.name == ChatList.assistant ? "sparkles" : "person.crop.circle")
        content.imageProperties.tintColor = row.isRunning ? .tintColor : .secondaryLabel
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        content.text = row.daemonName.map { "\(row.ref.name) · \($0)" } ?? row.ref.name
        content.textProperties.font = .preferredFont(forTextStyle: row.unread > 0 ? .headline : .body)
        content.secondaryText = row.lastMessage.map(ChatPresentation.preview) ?? String(localized: "No messages yet")
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 2
        content.textToSecondaryTextVerticalPadding = 3
        return content
    }

    private func render(_ newRows: [ChatRow], selection: AgentRef?) {
        let previous = rows
        rows = newRows
        var snapshot = NSDiffableDataSourceSnapshot<ChatRow.Section, AgentRef>()
        for section in [ChatRow.Section.pinned, .recent, .running] {
            let refs = newRows.filter { $0.section == section }.map(\.ref)
            guard !refs.isEmpty else { continue }
            snapshot.appendSections([section])
            snapshot.appendItems(refs, toSection: section)
        }
        let changed = newRows.filter { row in previous.first { $0.ref == row.ref } != row }.map(\.ref)
        snapshot.reconfigureItems(changed.filter { snapshot.itemIdentifiers.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: !previous.isEmpty)
        if let selection, splitViewController?.isCollapsed == false, let indexPath = dataSource.indexPath(for: selection) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
        if newRows.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "bubble.left.and.bubble.right")
            configuration.text = String(localized: "No Chats")
            configuration.secondaryText = String(localized: "Start a chat with any agent on your paired daemons.")
            contentUnavailableConfiguration = configuration
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let ref = dataSource.itemIdentifier(for: indexPath) else { return }
        store.send(.chats(.rowTapped(ref)))
        (splitViewController as? RootSplitViewController)?.showSelectedAgent()
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
        // Dismissing the sheet first, then showing the thread.
        let split = presentingViewController?.splitViewController as? RootSplitViewController
        split?.showSelectedAgent()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
