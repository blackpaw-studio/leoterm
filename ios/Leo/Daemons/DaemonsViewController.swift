import ComposableArchitecture
import LeoFeatures
import UIKit
import UIKitNavigation

/// The paired daemons and their connection status. Swipe to forget.
final class DaemonsViewController: UIViewController, UICollectionViewDelegate {
    @UIBindable private var store: StoreOf<Daemons>
    private let fleet: StoreOf<Fleet>
    private var sessions: [DaemonSession] = []
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(store: StoreOf<Daemons>, fleet: StoreOf<Fleet>) {
        self.store = store
        self.fleet = fleet
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Daemons")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        let add = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.store.send(.addButtonTapped) })
        add.accessibilityLabel = String(localized: "Pair a Daemon")
        add.accessibilityIdentifier = "daemons.add"
        navigationItem.rightBarButtonItem = add

        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "daemons.list"
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

        observe { [weak self] in
            guard let self else { return }
            render(Array(fleet.sessions))
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.footerMode = .supplementary
            configuration.trailingSwipeActionsConfigurationProvider = { indexPath in
                guard let self, let session = self.session(at: indexPath) else { return nil }
                let forget = UIContextualAction(style: .destructive, title: String(localized: "Forget")) { [weak self] _, _, done in
                    self?.store.send(.forgetButtonTapped(session.daemon))
                    done(true)
                }
                forget.image = UIImage(systemName: "trash")
                return UISwipeActionsConfiguration(actions: [forget])
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let session = self?.sessions.first(where: { $0.id == id }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.image = UIImage(systemName: "server.rack")
            content.imageProperties.tintColor = session.connection.tint
            content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
            content.text = session.daemon.name
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            let agents = session.agents.count
            let status = session.connection.isConnected
                ? String(localized: "\(session.connection.label) · \(agents) agents")
                : session.connection.label
            content.secondaryText = [session.daemon.displayHost, status, session.connection.detail].compactMap { $0 }.joined(separator: "\n")
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.textToSecondaryTextVerticalPadding = 3
            cell.contentConfiguration = content
            let dot = UIImageView(image: UIImage(systemName: "circle.fill"))
            dot.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9)
            cell.accessories = [.customView(configuration: .init(customView: dot, placement: .trailing(), tintColor: session.connection.tint))]
            cell.accessibilityIdentifier = "daemon.\(session.daemon.name)"
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = String(localized: "To add a daemon, run leo pair on the machine running Leo, then tap + to scan its QR code or paste its pairing code. Swipe left to forget one.")
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func session(at indexPath: IndexPath) -> DaemonSession? {
        dataSource.itemIdentifier(for: indexPath).flatMap { id in sessions.first { $0.id == id } }
    }

    private func render(_ newSessions: [DaemonSession]) {
        sessions = newSessions
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        if !newSessions.isEmpty {
            snapshot.appendSections([0])
            snapshot.appendItems(newSessions.map(\.id))
            snapshot.reconfigureItems(newSessions.map(\.id))
        }
        dataSource.apply(snapshot, animatingDifferences: true)

        if newSessions.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "server.rack")
            configuration.text = String(localized: "No Daemons")
            configuration.secondaryText = String(localized: "Run leo pair on a machine running Leo to get a pairing code.")
            var button = UIButton.Configuration.prominentGlass()
            button.title = String(localized: "Pair a Daemon")
            configuration.button = button
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.store.send(.addButtonTapped) }
            contentUnavailableConfiguration = configuration
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let session = session(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Reconnect"), image: UIImage(systemName: "arrow.clockwise")) { _ in
                    self?.store.send(.retryButtonTapped(session.id))
                },
                UIAction(title: String(localized: "Forget"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self?.store.send(.forgetButtonTapped(session.daemon))
                },
            ])
        })
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool { false }
}
