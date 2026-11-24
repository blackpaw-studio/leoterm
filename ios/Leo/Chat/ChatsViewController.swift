import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// The Chats inbox: every thread across paired daemons, the ones that need
/// you first, with filter chips and search. "New chat" picks any agent.
final class ChatsViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    @UIBindable private var store: StoreOf<AppFeature>
    /// What a list entry is: a thread row, or an inbox card (needs-you and done lists).
    private enum Item: Hashable {
        case row(AgentRef)
        case card(LeoAgentID)
    }

    private var rows: [ChatRow] = []
    private var cards: [LeoAgentID: LeoInboxItem] = [:]
    private var cardRows: [LeoAgentID: ChatRow] = [:]
    private var askErrors: [LeoAgentID: String] = [:]
    private var inbox = LeoInbox.empty
    fileprivate var sectionTitles: [SectionTitleInfo?] = []
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
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
            inbox = store.inbox
            askErrors = store.chats.askErrors
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
        let card = UICollectionView.CellRegistration<UICollectionViewListCell, LeoAgentID> { [weak self] cell, _, id in
            guard let self, let item = cards[id] else { return }
            var configuration = ChatInboxCardConfiguration(item: item, row: cardRows[id], error: askErrors[id])
            configuration.actions = actions(for: item)
            cell.contentConfiguration = configuration
            cell.accessories = []
            cell.accessibilityIdentifier = "inbox.\(item.agent)"
            cell.accessibilityLabel = configuration.accessibilityText
        }
        let header = UICollectionView.SupplementaryRegistration<ChatFilterBar>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] bar, _, _ in
            guard let self else { return }
            filterBar = bar
            bar.onPick = { [weak self] filter in self?.store.send(.chats(.filterPicked(filter))) }
            bar.onClear = { [weak self] in self?.clearFinished() }
            bar.update(selected: selectedFilter, counts: counts, title: sectionTitles.first.flatMap { $0 })
        }
        let sectionHeader = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.sectionTitles[safe: indexPath.section]??.text.localizedUppercase
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .row(let ref): collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: ref)
            case .card(let id): collectionView.dequeueConfiguredReusableCell(using: card, for: indexPath, item: id)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            indexPath.section == 0
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: sectionHeader, for: indexPath)
        }
    }

    private func render(all: [ChatRow], visible: [ChatRow], filter: ChatFilter, search: String, selection: AgentRef?, hasDaemons: Bool) {
        let previous = rows
        let previousCards = cards
        selectedFilter = filter
        counts = ChatList.counts(all)
        counts.needsYou = inbox.blocked.count
        let content = content(rows: visible, all: all, filter: filter, search: search)
        rows = visible
        cards = content.cards
        cardRows = Dictionary(all.map { (LeoAgentID(host: .remote($0.ref.daemonID), name: $0.ref.name), $0) }, uniquingKeysWith: { $1 })
        sectionTitles = content.titles
        filterBar?.update(selected: filter, counts: counts, title: content.titles.first.flatMap { $0 })
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        for (index, items) in content.sections.enumerated() {
            snapshot.appendSections([index])
            snapshot.appendItems(items, toSection: index)
        }
        let changedRows = visible.filter { row in previous.first { $0.ref == row.ref } != row }.map { Item.row($0.ref) }
        let changedCards = cards.filter { previousCards[$0.key] != $0.value || askErrors[$0.key] != nil }.map { Item.card($0.key) }
        snapshot.reconfigureItems((changedRows + changedCards).filter { snapshot.itemIdentifiers.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: !previous.isEmpty || !previousCards.isEmpty)
        if let selection, splitViewController?.isCollapsed == false, let indexPath = dataSource.indexPath(for: .row(selection)) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
        let isEmpty = content.sections.allSatisfy(\.isEmpty)
        contentUnavailableConfiguration = isEmpty ? emptyState(filter: filter, search: search, hasChats: !all.isEmpty, hasDaemons: hasDaemons) : nil
    }

    /// The list for the chip: inbox cards under Needs you and Done, thread rows elsewhere.
    private func content(rows: [ChatRow], all: [ChatRow], filter: ChatFilter, search: String) -> (sections: [[Item]], titles: [SectionTitleInfo?], cards: [LeoAgentID: LeoInboxItem]) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func matching(_ items: [LeoInboxItem]) -> [LeoInboxItem] {
            items.filter { query.isEmpty || $0.agent.localizedCaseInsensitiveContains(query) }
        }
        func byID(_ items: [LeoInboxItem]) -> [LeoAgentID: LeoInboxItem] { Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }) }
        switch filter {
        case .needsYou:
            let blocked = matching(inbox.blocked)
            return ([blocked.map { .card($0.id) }], [nil], byID(blocked))
        case .done:
            let finished = matching(inbox.finished)
            let unread = finished.filter(\.isUnread)
            let earlier = finished.filter { !$0.isUnread }
            if unread.isEmpty {
                return ([earlier.map { .card($0.id) }], [SectionTitleInfo(text: String(localized: "Earlier"))], byID(finished))
            }
            return (
                [unread.map { .card($0.id) }, earlier.map { .card($0.id) }].filter { !$0.isEmpty },
                [SectionTitleInfo(text: String(localized: "Since you looked"), canClear: true), earlier.isEmpty ? nil : SectionTitleInfo(text: String(localized: "Earlier"))],
                byID(finished)
            )
        case .all, .working:
            return ([rows.map { .row($0.ref) }], [nil], [:])
        }
    }

    private func actions(for item: LeoInboxItem) -> ChatInboxCardActions {
        guard case .remote(let daemonID) = item.id.host else { return ChatInboxCardActions() }
        let ref = AgentRef(daemonID: daemonID, name: item.agent)
        var actions = ChatInboxCardActions()
        actions.openChat = { [weak self] in self?.store.send(.chatOpened(ref)) }
        actions.goToAgent = { [weak self] in self?.store.send(.notificationOpened(ref)) }
        if case .chatAsk(let message) = item.kind {
            actions.answer = { [weak self] answer in
                self?.store.send(.chats(.askAnswered(daemonID: daemonID, agent: item.agent, messageID: message.id, answer)))
            }
        }
        return actions
    }

    private func clearFinished() {
        store.send(.chats(.clearFinishedTapped(inbox.finished)))
    }

    private func emptyState(filter: ChatFilter, search: String, hasChats: Bool, hasDaemons: Bool) -> UIContentUnavailableConfiguration {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .search() }
        var configuration = UIContentUnavailableConfiguration.empty()
        if filter != .all, hasChats {
            let (symbol, text) = switch filter {
            case .needsYou: ("checkmark.circle", String(localized: "Nothing needs you"))
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

    /// A blocked card answers through its own controls; rows and finished cards open the thread.
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard case .card(let id)? = dataSource.itemIdentifier(for: indexPath) else { return true }
        return cards[id]?.isBlocked == false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .row(let ref)?:
            store.send(.chats(.rowTapped(ref)))
        case .card(let id)?:
            guard case .remote(let daemonID) = id.host else { return }
            store.send(.chats(.rowTapped(AgentRef(daemonID: daemonID, name: id.name))))
        case nil:
            break
        }
    }

    /// Long press: the Agents tab's menu. Rows with no agent record (e.g. a
    /// thread whose daemon dropped the agent) get none.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .row(let ref)? = indexPaths.first.flatMap({ dataSource.itemIdentifier(for: $0) }) else { return nil }
        return AgentContextMenu.configuration(for: ref, store: store)
    }
}

/// The chip row above the inbox: All, Needs you, Working, Done; under Done,
/// the first section's title with its Clear button.
final class ChatFilterBar: UICollectionReusableView {
    var onPick: (ChatFilter) -> Void = { _ in }
    var onClear: () -> Void = {}
    private var buttons: [ChatFilter: UIButton] = [:]
    private let titleLabel = UILabel()
    private let clearButton = UIButton(type: .system)
    private let titleRow = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
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
        titleLabel.font = .preferredFont(forTextStyle: .footnote)
        titleLabel.textColor = .secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true
        var clear = UIButton.Configuration.plain()
        clear.title = String(localized: "Clear")
        clear.contentInsets = .zero
        clearButton.configuration = clear
        clearButton.accessibilityIdentifier = "inbox.clear"
        clearButton.addAction(UIAction { [weak self] _ in self?.onClear() }, for: .touchUpInside)
        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(UIView())
        titleRow.addArrangedSubview(clearButton)
        titleRow.isLayoutMarginsRelativeArrangement = true
        titleRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        let column = UIStackView(arrangedSubviews: [scroll, titleRow])
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            scroll.heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: 0),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    fileprivate func update(selected: ChatFilter, counts: ChatCounts, title: SectionTitleInfo?) {
        for (filter, button) in buttons {
            var configuration = filter == selected ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            configuration.cornerStyle = .capsule
            configuration.title = filter.title(counts: counts)
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            button.configuration = configuration
            button.isSelected = filter == selected
            button.accessibilityTraits = filter == selected ? [.button, .selected] : .button
        }
        titleRow.isHidden = title == nil
        titleLabel.text = title?.text.localizedUppercase
        clearButton.isHidden = title?.canClear != true
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
            content.text = agent.displayName
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
                let ordered = section.agents.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                snapshot.appendItems(ordered.map { AgentRef(daemonID: section.id, name: $0.name) }, toSection: section.id)
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

/// The text above a section, and whether it offers Clear.
fileprivate struct SectionTitleInfo: Equatable {
    let text: String
    var canClear = false
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
