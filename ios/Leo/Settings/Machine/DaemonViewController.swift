import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// The Daemon screen: Service, Web UI, Remote client and Remote hosts, in the
/// Mac pane's order. Each row pushes its own screen; the restart question is
/// the machine's, so every child is handed the machine's restart store.
final class DaemonViewController: UIViewController, UICollectionViewDelegate {
    @UIBindable private var store: StoreOf<DaemonSettings>
    private let restart: StoreOf<MachineRestart>
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, LeoDaemonPane.Section>!

    init(store: StoreOf<DaemonSettings>, restart: StoreOf<MachineRestart>) {
        self.store = store
        self.restart = restart
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Daemon")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backBarButtonItem = NoHistoryBackBarButtonItem()
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "daemon.list"
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()
        bindDestinations()
        var snapshot = NSDiffableDataSourceSnapshot<Int, LeoDaemonPane.Section>()
        snapshot.appendSections([0])
        snapshot.appendItems(store.sections)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func bindDestinations() {
        let restart = restart
        navigationDestination(item: $store.scope(state: \.destination?.service, action: \.destination.service)) { store in
            ServiceViewController(store: store, restart: restart)
        }
        navigationDestination(item: $store.scope(state: \.destination?.web, action: \.destination.web)) { store in
            ConfigSingletonViewController(store: store, restart: restart)
        }
        navigationDestination(item: $store.scope(state: \.destination?.client, action: \.destination.client)) { store in
            ConfigSingletonViewController(store: store, restart: restart)
        }
        navigationDestination(item: $store.scope(state: \.destination?.hosts, action: \.destination.hosts)) { store in
            ConfigCollectionViewController(store: store, restart: restart)
        }
    }

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, LeoDaemonPane.Section> { cell, _, section in
            var content = UIListContentConfiguration.cell()
            content.text = DaemonSettings.title(for: section)
            content.image = UIImage(systemName: section.symbol)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "daemon.section.\(section.rawValue)"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, section in
            collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: section)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let section = dataSource.itemIdentifier(for: indexPath) else { return }
        store.send(.sectionTapped(section))
    }
}

extension LeoDaemonPane.Section {
    var symbol: String {
        switch self {
        case .service: "server.rack"
        case .web: "globe"
        case .client: "arrow.left.arrow.right"
        case .hosts: "terminal"
        }
    }
}
