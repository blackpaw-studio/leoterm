import ComposableArchitecture
import LeoFeatures
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
        navigationController?.navigationBar.prefersLargeTitles = true
        let daemonsButton = UIBarButtonItem(
            image: UIImage(systemName: "server.rack"),
            primaryAction: UIAction { [weak self] _ in self?.store.send(.daemonsButtonTapped) }
        )
        daemonsButton.accessibilityLabel = String(localized: "Daemons")
        navigationItem.rightBarButtonItem = daemonsButton
        let settingsButton = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in self?.store.send(.settingsButtonTapped) }
        )
        settingsButton.accessibilityLabel = String(localized: "Settings")
        navigationItem.leftBarButtonItem = settingsButton

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

        navigationDestination(isPresented: $store.isShowingDaemons) { [store] in
            DaemonsViewController(store: store.scope(state: \.daemons, action: \.daemons), fleet: store.scope(state: \.fleet, action: \.fleet))
        }
        navigationDestination(isPresented: $store.isShowingSettings) { [store] in
            SettingsViewController(store: store.scope(state: \.push, action: \.push))
        }

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
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, AgentRef> { [weak self] cell, _, ref in
            guard let agent = self?.agent(ref) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            let badge = agent.badge
            content.image = UIImage(systemName: badge.symbol)
            content.imageProperties.tintColor = badge.tint
            content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
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
        snapshot.reconfigureItems(changed.filter { snapshot.itemIdentifiers.contains($0) })
        let headersChanged = previous.map(\.connection) != newSections.map(\.connection) || previous.map(\.id) != newSections.map(\.id)
        if headersChanged { snapshot.reloadSections(newSections.map(\.id).filter { previous.map(\.id).contains($0) }) }
        dataSource.apply(snapshot, animatingDifferences: !previous.isEmpty)

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

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let ref = dataSource.itemIdentifier(for: indexPath) else { return }
        store.send(.agentTapped(ref))
        (splitViewController as? RootSplitViewController)?.showSelectedAgent()
    }
}
