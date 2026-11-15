import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// One machine: its info card, then the Configuration rows that open its
/// Templates, Environments and Tasks. A machine that is down shows its status and a
/// Reconnect; one whose daemon is too old says what it requires.
final class MachineSettingsViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Int { case info, configuration }

    private enum Item: Hashable {
        case info
        case row(MachineSettings.Row)
        case note(String)
        case status(String)
        case reconnect
    }

    @UIBindable private var store: StoreOf<MachineSettings>
    private let fleet: StoreOf<Fleet>
    private var session: DaemonSession?
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var restartAlertToken: ObserveToken?

    init(store: StoreOf<MachineSettings>, fleet: StoreOf<Fleet>) {
        self.store = store
        self.fleet = fleet
        super.init(nibName: nil, bundle: nil)
        title = store.link.daemon.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "machine.list"
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()

        present(item: $store.scope(state: \.alert, action: \.alert)) { store in
            UIAlertController(store: store)
        }
        navigationDestination(item: $store.scope(state: \.destination?.templates, action: \.destination.templates)) { [weak self] store in
            ConfigCollectionViewController(store: store, restart: self?.restartStore)
        }
        navigationDestination(item: $store.scope(state: \.destination?.environments, action: \.destination.environments)) { [weak self] store in
            ConfigCollectionViewController(store: store, restart: self?.restartStore)
        }
        navigationDestination(item: $store.scope(state: \.destination?.tasks, action: \.destination.tasks)) { [weak self] store in
            TasksViewController(store: store, restart: self?.restartStore)
        }
        navigationDestination(item: $store.scope(state: \.destination?.service, action: \.destination.service)) { [weak self] store in
            ServiceViewController(store: store, restart: self?.restartStore ?? Store(initialState: MachineRestart.State(machine: "")) { MachineRestart() })
        }
        bindRestartAlert()

        observe { [weak self] in
            guard let self else { return }
            render(availability: store.availability, session: fleet.sessions[id: store.id])
        }
    }

    private var restartStore: StoreOf<MachineRestart> { store.scope(state: \.restart, action: \.restart) }

    /// The restart's questions and answers are asked of whichever screen is
    /// showing (a config form, the Service screen), so they are presented
    /// from the navigation controller, not from this screen, which a pane
    /// may be covering.
    private func bindRestartAlert() {
        let host: UIViewController = navigationController ?? self
        restartAlertToken = host.present(item: $store.scope(state: \.restart.alert, action: \.restart.alert)) { store in
            UIAlertController(store: store)
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .none
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let info = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self, let session else { return }
            cell.contentConfiguration = MachineCellConfiguration(session: session, style: .off)
            cell.accessories = []
            cell.accessibilityIdentifier = "machine.info"
        }
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            var content = UIListContentConfiguration.cell()
            cell.accessories = []
            switch item {
            case .row(let row):
                content.text = row.title
                content.image = UIImage(systemName: row.symbol)
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "machine.config.\(row.rawValue)"
            case .note(let text):
                content.text = text
                content.textProperties.color = .secondaryLabel
                cell.accessibilityIdentifier = "machine.config.requires"
            case .status(let text):
                content.text = text
                content.textProperties.color = .secondaryLabel
                cell.accessibilityIdentifier = "machine.config.status"
            case .reconnect:
                content.text = String(localized: "Reconnect")
                content.image = UIImage(systemName: "arrow.clockwise")
                content.textProperties.color = cell.tintColor
                cell.accessibilityIdentifier = "machine.config.reconnect"
            case .info:
                break
            }
            cell.contentConfiguration = content
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { view, _, _ in
            var content = UIListContentConfiguration.header()
            content.text = String(localized: "Configuration")
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: item == .info ? info : row, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func render(availability: MachineSettings.Availability, session: DaemonSession?) {
        self.session = session
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if session != nil {
            snapshot.appendSections([.info])
            snapshot.appendItems([.info])
            snapshot.reconfigureItems([.info])
        }
        snapshot.appendSections([.configuration])
        switch availability {
        case .rows(let rows): snapshot.appendItems(rows.map(Item.row))
        case .requires(let text): snapshot.appendItems([.note(text)])
        case .unavailable(let status): snapshot.appendItems([.status(status.label), .reconnect])
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .row?, .reconnect?: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .row(let row)?: store.send(.rowTapped(row))
        case .reconnect?: store.send(.reconnectTapped)
        default: break
        }
    }
}

extension MachineSettings.Row {
    var symbol: String {
        switch self {
        case .templates: "doc.on.doc"
        case .environments: "square.stack.3d.up"
        case .tasks: "checklist"
        case .service: "server.rack"
        }
    }
}
