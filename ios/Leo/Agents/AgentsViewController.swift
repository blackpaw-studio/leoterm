import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// Every agent on every paired daemon, grouped by daemon, attention first.
final class AgentsViewController: UIViewController, UICollectionViewDelegate {
    @UIBindable private var store: StoreOf<AppFeature>
    private var sections: [AgentSection] = []
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<String, AgentRef>!

    init(store: StoreOf<AppFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Agents")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "agents.list"
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()

        observe { [weak self] in
            guard let self else { return }
            render(sections: store.fleet.sections, selection: store.detail?.ref)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Collapsed (iPhone): coming back from an agent clears the highlight.
        if splitViewController?.isCollapsed == true, let selected = collectionView.indexPathsForSelectedItems?.first {
            collectionView.deselectItem(at: selected, animated: animated)
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in self?.swipeActions(at: indexPath) }
            // A single machine's name and status are on the Machines screen.
            configuration.headerMode = (self?.sections.count ?? 0) > 1 ? .supplementary : .none
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, AgentRef> { [weak self] cell, _, ref in
            guard let agent = self?.agent(ref) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            let badge = agent.badge
            let style = agent.rowStyle
            switch style.leading {
            case .status(let symbol, let tint):
                content.image = UIImage(systemName: symbol)
                content.imageProperties.tintColor = tint
                content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
            case .tile(let emoji, let statusTint):
                content.image = AgentRowTile.image(emoji: emoji, statusTint: statusTint)
            }
            // With any tile on screen every row's image gets the tile's width, so names stay aligned.
            if self?.showsTiles == true { content.imageProperties.reservedLayoutSize = AgentRowTile.size }
            content.text = agent.name
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryText = agent.summary
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 2
            content.textToSecondaryTextVerticalPadding = 3
            cell.contentConfiguration = content
            var accessories: [UICellAccessory] = [.disclosureIndicator()]
            if agent.priority.needsAttention {
                accessories.insert(.customView(configuration: .init(customView: BadgeView(text: badge.label, tint: badge.tint), placement: .trailing())), at: 0)
            }
            cell.accessories = accessories
            cell.accessibilityIdentifier = "agent.\(agent.name)"
            cell.accessibilityValue = style.bar?.displayName
            cell.configurationUpdateHandler = { cell, state in
                var background = UIBackgroundConfiguration.listCell().updated(for: state)
                background.customView = style.bar.map { AgentRowBackground(barColor: $0.uiColor) }
                cell.backgroundConfiguration = background
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            guard let self, let id = dataSource.sectionIdentifier(for: indexPath.section),
                  let section = sections.first(where: { $0.id == id }) else { return }
            var content = UIListContentConfiguration.prominentInsetGroupedHeader()
            content.text = section.daemon.name
            content.secondaryText = section.connection.label
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.secondaryTextProperties.color = section.connection.isConnected ? .secondaryLabel : section.connection.tint
            content.prefersSideBySideTextAndSecondaryText = true
            content.image = UIImage(systemName: "circle.fill")
            content.imageProperties.tintColor = section.connection.tint
            content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9)
            content.imageToTextPadding = 6
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, ref in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: ref)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// Whether any row shows an emoji tile, which is wider than the status symbol.
    private var showsTiles: Bool {
        sections.contains { $0.agents.contains { $0.appearance?.emoji != nil } }
    }

    private func agent(_ ref: AgentRef) -> Agent? {
        sections.first { $0.id == ref.daemonID }?.agents.first { $0.name == ref.name }
    }

    private func render(sections newSections: [AgentSection], selection: AgentRef?) {
        let previous = sections
        sections = newSections
        var snapshot = NSDiffableDataSourceSnapshot<String, AgentRef>()
        for section in newSections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.agents.map { AgentRef(daemonID: section.id, name: $0.name) }, toSection: section.id)
        }
        let changed = newSections.flatMap { section in
            section.agents.compactMap { agent -> AgentRef? in
                let old = previous.first { $0.id == section.id }?.agents.first { $0.name == agent.name }
                return old == agent ? nil : AgentRef(daemonID: section.id, name: agent.name)
            }
        }
        let tilesChanged = previous.contains { $0.agents.contains { $0.appearance?.emoji != nil } } != showsTiles
        snapshot.reconfigureItems((tilesChanged ? snapshot.itemIdentifiers : changed).filter { snapshot.itemIdentifiers.contains($0) })
        let headersChanged = previous.map(\.connection) != newSections.map(\.connection) || previous.map(\.id) != newSections.map(\.id)
        if headersChanged { snapshot.reloadSections(newSections.map(\.id).filter { previous.map(\.id).contains($0) }) }
        dataSource.apply(snapshot, animatingDifferences: !previous.isEmpty)
        if (previous.count > 1) != (newSections.count > 1) { collectionView.collectionViewLayout.invalidateLayout() }

        if let selection, splitViewController?.isCollapsed == false, let indexPath = dataSource.indexPath(for: selection) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
        updateEmptyState()
    }

    private func updateEmptyState() {
        if sections.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
            configuration.text = String(localized: "No Daemons Paired")
            configuration.secondaryText = String(localized: "Run leo pair on a machine running Leo, then scan its QR code or paste the pairing code.")
            var button = UIButton.Configuration.prominentGlass()
            button.title = String(localized: "Pair a Daemon")
            configuration.button = button
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.store.send(.pairButtonTapped) }
            contentUnavailableConfiguration = configuration
        } else if sections.allSatisfy(\.agents.isEmpty) {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "person.2.slash")
            configuration.text = String(localized: "No Agents")
            configuration.secondaryText = String(localized: "Agents running on your paired daemons appear here.")
            contentUnavailableConfiguration = configuration
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    /// Long press: Move To ▸, Copy To ▸ and Duplicate… (B-324), and Appearance on
    /// a daemon that can resolve it. No menu when there is nothing to offer.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let ref = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let supportsAppearance = store.fleet.sessions[id: ref.daemonID]?.supportsAppearance == true
        let moves = moveMenu(for: ref)
        guard supportsAppearance || !moves.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            var children: [UIMenuElement] = self?.moveMenu(for: ref) ?? []
            if supportsAppearance {
                let appearance = UIAction(title: String(localized: "Appearance…"), image: UIImage(systemName: "paintpalette")) { _ in
                    self?.store.send(.appearanceRequested(ref))
                }
                appearance.accessibilityIdentifier = "agent.appearance"
                children.append(appearance)
            }
            return UIMenu(children: children)
        })
    }

    /// Move To ▸ and Copy To ▸ over the daemon's hosts, then Duplicate…; empty
    /// for an agent that can't move or a daemon without `agent_move`.
    private func moveMenu(for ref: AgentRef) -> [UIMenuElement] {
        guard agent(ref)?.canMove == true else { return [] }
        let availability = store.withState { $0.moveAvailability(for: ref.daemonID) }
        guard availability.offersDuplicate else { return [] }
        var elements: [UIMenuElement] = []
        if !availability.hosts.isEmpty {
            let move = UIMenu(title: String(localized: "Move To"), image: UIImage(systemName: "arrow.right.circle"), children: availability.hosts.map { host in
                UIAction(title: host) { [weak self] _ in self?.store.send(.moveRequested(ref, .move(to: host))) }
            })
            let copy = UIMenu(title: String(localized: "Copy To"), image: UIImage(systemName: "doc.on.doc"), children: availability.hosts.map { host in
                UIAction(title: host) { [weak self] _ in self?.store.send(.moveRequested(ref, .copy(to: host))) }
            })
            move.accessibilityIdentifier = "agent.move.to"
            copy.accessibilityIdentifier = "agent.move.copyTo"
            elements += [move, copy]
        }
        let duplicate = UIAction(title: String(localized: "Duplicate…"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
            self?.store.send(.moveRequested(ref, .duplicate))
        }
        duplicate.accessibilityIdentifier = "agent.move.duplicate"
        return elements + [duplicate]
    }

    /// Trailing swipe: Move opens the same choices as a sheet.
    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let ref = dataSource.itemIdentifier(for: indexPath), !moveMenu(for: ref).isEmpty else { return nil }
        let action = UIContextualAction(style: .normal, title: String(localized: "Move")) { [weak self] _, _, done in
            self?.presentMoveSheet(for: ref, at: indexPath)
            done(true)
        }
        action.image = UIImage(systemName: "arrow.right.circle")
        action.backgroundColor = .systemIndigo
        return UISwipeActionsConfiguration(actions: [action])
    }

    private func presentMoveSheet(for ref: AgentRef, at indexPath: IndexPath) {
        let availability = store.withState { $0.moveAvailability(for: ref.daemonID) }
        let sheet = UIAlertController(title: ref.name, message: nil, preferredStyle: .actionSheet)
        for host in availability.hosts {
            sheet.addAction(UIAlertAction(title: String(localized: "Move to \(host)"), style: .default) { [weak self] _ in
                self?.store.send(.moveRequested(ref, .move(to: host)))
            })
        }
        for host in availability.hosts {
            sheet.addAction(UIAlertAction(title: String(localized: "Copy to \(host)"), style: .default) { [weak self] _ in
                self?.store.send(.moveRequested(ref, .copy(to: host)))
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Duplicate…"), style: .default) { [weak self] _ in
            self?.store.send(.moveRequested(ref, .duplicate))
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = collectionView
            popover.sourceRect = collectionView.cellForItem(at: indexPath)?.frame ?? .zero
        }
        present(sheet, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let ref = dataSource.itemIdentifier(for: indexPath) else { return }
        store.send(.agentTapped(ref))
    }
}
