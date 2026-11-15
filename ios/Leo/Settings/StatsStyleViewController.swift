import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// Settings > Stats style: a checkmark list with a live preview card.
final class StatsStyleViewController: UIViewController, UICollectionViewDelegate {
    private enum Item: Hashable {
        case preview
        case style(LeoStatsStyle)
    }

    private static let sampleMeters = LeoMachineStats(
        sampledAt: Date(),
        cpu: .init(percent: 23, cores: 8),
        memory: .init(usedBytes: 85, totalBytes: 100),
        disk: .init(path: "/", usedBytes: 47, totalBytes: 100)
    ).meters

    private let store: StoreOf<AppFeature>
    private var style = LeoStatsStyle.default
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init(store: StoreOf<AppFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Stats style")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        collectionView.accessibilityIdentifier = "settings.statsStyle"
        collectionView.delegate = self
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
            render(style: store.fleet.statsStyle)
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            configuration.footerMode = .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .preview:
                var daemon = DaemonSession(daemon: PairedDaemonPreview.sample)
                daemon.connection = .connected
                var configuration = MachineCellConfiguration(session: daemon, style: style)
                configuration.address = String(localized: "dionysus.lan · 3 agents")
                configuration.meters = style.showsMeters ? Self.sampleMeters : nil
                cell.contentConfiguration = configuration
                cell.accessories = []
            case .style(let option):
                var content = cell.defaultContentConfiguration()
                content.text = option.title
                cell.contentConfiguration = content
                cell.accessories = option == style ? [.checkmark()] : []
                cell.accessibilityIdentifier = "settings.statsStyle.\(option.rawValue)"
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = indexPath.section == 0 ? String(localized: "Preview") : nil
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = indexPath.section == 1
                ? String(localized: "Applies to the Machines list. Stored on this device only.")
                : nil
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func render(style newStyle: LeoStatsStyle) {
        style = newStyle
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems([.preview], toSection: 0)
        snapshot.appendItems(LeoStatsStyle.allCases.map(Item.style), toSection: 1)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .style = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .style(let option) = dataSource.itemIdentifier(for: indexPath) else { return }
        store.send(.statsStyleSelected(option))
    }
}

/// The daemon the preview card pretends to be.
private enum PairedDaemonPreview {
    static let sample = PairedDaemon(
        id: "preview", name: "Dionysus", baseURL: URL(string: "https://dionysus.lan")!,
        urls: [], deviceID: "", pairedAt: Date()
    )
}
