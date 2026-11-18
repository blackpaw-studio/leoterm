import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// One profile's roles: what each routes to, or "Not routed". A role opens
/// its cell editor; Make Active previews what switching changes first. The
/// sheets are presented by the Delegation screen, which owns them.
final class DelegationProfileViewController: UIViewController, UICollectionViewDelegate {
    private let store: StoreOf<DelegationSettings>
    private let restart: StoreOf<MachineRestart>?
    private var profile: String
    private let banners = ConfigBannerStack()
    private let activateButton = UIBarButtonItem(title: String(localized: "Make Active"), style: .plain, target: nil, action: nil)
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(store: StoreOf<DelegationSettings>, restart: StoreOf<MachineRestart>?, profile: String) {
        self.store = store
        self.restart = restart
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
        title = profile
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        activateButton.primaryAction = UIAction(title: String(localized: "Make Active")) { [weak self] _ in
            guard let self else { return }
            store.send(.activateTapped(profile))
        }
        activateButton.accessibilityIdentifier = "delegation.activate"
        navigationItem.rightBarButtonItem = activateButton
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "delegation.profile.list"
        let stack = UIStackView(arrangedSubviews: [banners, collectionView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()
        observe { [weak self] in self?.render() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent, store.openProfile != nil { store.send(.profileClosed) }
    }

    private func render() {
        if let open = store.openProfile { profile = open }
        title = profile
        banners.show(ConfigBanners.banners(store, restart: restart))
        let isActive = store.core.matrix.activeProfile?.name == profile
        activateButton.isHidden = isActive
        activateButton.isEnabled = store.core.canWrite && store.core.preview == nil
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(store.state.roles(in: profile).map(\.role))
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, role in
            guard let self, let row = store.state.roles(in: profile).first(where: { $0.role == role }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.role
            content.secondaryText = row.summary
            content.secondaryTextProperties.color = row.isRouted ? .secondaryLabel : .tertiaryLabel
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "delegation.cell.\(row.role)"
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.header()
            content.text = store.core.matrix.activeProfile?.name == profile
                ? String(localized: "Roles · Active profile") : String(localized: "Roles")
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, role in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: role)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let role = dataSource.itemIdentifier(for: indexPath) else { return }
        store.send(.cellTapped(profile: profile, role: role))
    }
}
