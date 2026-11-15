import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// The paired machines with their connection status and live CPU, memory and
/// disk meters. Swipe to forget.
final class DaemonsViewController: UIViewController, UICollectionViewDelegate {
    @UIBindable private var store: StoreOf<Daemons>
    private let fleet: StoreOf<Fleet>
    private var sessions: [DaemonSession] = []
    private var rows: [String: MachineCellConfiguration] = [:]
    private var statsStyle = LeoStatsStyle.default
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(store: StoreOf<Daemons>, fleet: StoreOf<Fleet>) {
        self.store = store
        self.fleet = fleet
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Machines")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        let add = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.store.send(.addButtonTapped) })
        add.accessibilityLabel = String(localized: "Pair a Machine")
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
        navigationDestination(item: $store.scope(state: \.machine, action: \.machine)) { [fleet] store in
            MachineSettingsViewController(store: store, fleet: fleet)
        }

        observe { [weak self] in
            guard let self else { return }
            render(Array(fleet.sessions), style: fleet.statsStyle)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.send(.appeared)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        store.send(.disappeared)
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.footerMode = .supplementary
            configuration.itemSeparatorHandler = { _, separator in
                var separator = separator
                separator.bottomSeparatorInsets.leading = 56
                return separator
            }
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
            guard let self, let row = rows[id] else { return }
            cell.contentConfiguration = row
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "daemon.\(row.name)"
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.footer()
            let refresh = self?.statsStyle.showsMeters == true
                ? String(localized: "Stats refresh every few seconds while this list is open. ")
                : ""
            content.text = String(localized: "To add a machine, run leo pair on it, then tap + to scan its QR code or paste its pairing code. ") + refresh + String(localized: "Swipe left to forget one.")
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

    /// The fleet changes with every agent event; only a row whose own content
    /// changed is reconfigured, so a touch on an untouched row is not disturbed.
    private func render(_ newSessions: [DaemonSession], style: LeoStatsStyle) {
        let styleChanged = style != statsStyle
        let previousRows = rows
        let newRows = Dictionary(uniqueKeysWithValues: newSessions.map { ($0.id, MachineCellConfiguration(session: $0, style: style)) })
        let ids = newSessions.map(\.id)
        let isSameList = ids == sessions.map(\.id)
        sessions = newSessions
        rows = newRows
        statsStyle = style
        let changedIDs = ids.filter { previousRows[$0] != newRows[$0] }
        if !isSameList || styleChanged || !changedIDs.isEmpty {
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            if !newSessions.isEmpty {
                snapshot.appendSections([0])
                snapshot.appendItems(ids)
                snapshot.reconfigureItems(changedIDs)
                // The footer's text depends on the style.
                if styleChanged { snapshot.reloadSections([0]) }
            }
            // A content-only update is not an insertion or removal: no animation.
            dataSource.apply(snapshot, animatingDifferences: !isSameList)
        }

        if newSessions.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "server.rack")
            configuration.text = String(localized: "No Machines")
            configuration.secondaryText = String(localized: "Run leo pair on a machine running Leo to get a pairing code.")
            var button = UIButton.Configuration.prominentGlass()
            button.title = String(localized: "Pair a Machine")
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

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if let session = session(at: indexPath) { store.send(.machineTapped(session.id)) }
    }
}
