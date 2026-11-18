import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// The Delegation screen: the switch, the profiles (the active one marked),
/// the roles, the hidden native agents, the daemon's warnings and the recent
/// role dispatches. A profile pushes its roles; every edit opens a sheet with
/// Cancel and Save. Renames, copies and deletes are swipe actions, held while
/// any edit is unsaved (`canRestructure`).
final class DelegationViewController: UIViewController, UICollectionViewDelegate {
    enum Section: Hashable { case main, profiles, roles, warnings, consults, web }

    enum Item: Hashable {
        case loading
        case failed(String)
        case retry
        case notConfigured
        case enabled
        case hiddenAgents
        case profile(String)
        case addProfile
        case role(String)
        case addRole
        case warning(String)
        case consult(String)
        case web
    }

    @UIBindable private var store: StoreOf<DelegationSettings>
    private let restart: StoreOf<MachineRestart>?
    private let banners = ConfigBannerStack()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private lazy var sheets = DelegationSheetPresenter(store: store, restart: restart) { [weak self] in
        self?.navigationController ?? self
    }
    private weak var profileScreen: DelegationProfileViewController?

    init(store: StoreOf<DelegationSettings>, restart: StoreOf<MachineRestart>? = nil) {
        self.store = store
        self.restart = restart
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Delegation")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backBarButtonItem = NoHistoryBackBarButtonItem()
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "delegation.list"
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

        present(item: $store.scope(state: \.alert, action: \.alert)) { store in
            UIAlertController(store: store)
        }
        present(item: $store.scope(state: \.nameEntry, action: \.nameEntry)) { store in
            let sheet = UINavigationController(rootViewController: NameEntryViewController(store: store))
            sheet.modalPresentationStyle = .formSheet
            return sheet
        }
        observe { [weak self] in self?.render() }
        store.send(.task)
    }

    // MARK: rendering

    private func render() {
        banners.show(ConfigBanners.banners(store, restart: restart))
        dataSource.apply(snapshot(), animatingDifferences: false)
        sheets.sync()
        syncProfile(store.openProfile)
    }

    private func snapshot() -> NSDiffableDataSourceSnapshot<Section, Item> {
        let core = store.core
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.main])
        switch core.phase {
        case .loading where core.document == nil:
            snapshot.appendItems([.loading])
        case .failed(let message) where core.document == nil:
            snapshot.appendItems([.failed(message), .retry])
        default:
            guard core.isConfigured else {
                snapshot.appendItems([.notConfigured])
                return snapshot
            }
            snapshot.appendItems([.enabled, .hiddenAgents])
            snapshot.appendSections([.profiles, .roles])
            snapshot.appendItems(core.matrix.profiles.map { .profile($0.name) } + [.addProfile], toSection: .profiles)
            snapshot.appendItems(core.matrix.rows.map { .role($0.role.name) } + [.addRole], toSection: .roles)
            if !core.warnings.isEmpty {
                snapshot.appendSections([.warnings])
                snapshot.appendItems(core.warnings.map(Item.warning), toSection: .warnings)
            }
            if !core.recentConsults.isEmpty {
                snapshot.appendSections([.consults])
                snapshot.appendItems(core.recentConsults.map { .consult($0.id) }, toSection: .consults)
            }
            if core.webLink != nil {
                snapshot.appendSections([.web])
                snapshot.appendItems([.web], toSection: .web)
            }
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        return snapshot
    }

    /// The profile screen is pushed while a profile is open and popped when
    /// the store lets go of it (it was deleted).
    private func syncProfile(_ profile: String?) {
        guard let navigationController else { return }
        let shown = profileScreen.flatMap { navigationController.viewControllers.contains($0) ? $0 : nil }
        if let profile, shown == nil {
            let pushed = DelegationProfileViewController(store: store, restart: restart, profile: profile)
            profileScreen = pushed
            navigationController.pushViewController(pushed, animated: true)
        } else if profile == nil, shown != nil {
            profileScreen = nil
            navigationController.popToViewController(self, animated: true)
        }
    }

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            DelegationCells.configure(cell, item: item, store: store)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self.flatMap { $0.dataSource.sectionIdentifier(for: indexPath.section) }.flatMap(DelegationCells.header)
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    // MARK: selection and swipes

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .retry?, .hiddenAgents?, .profile?, .web?: true
        case .addProfile?: store.core.canRestructure
        case .addRole?: store.core.canRestructure && !store.core.templates.isEmpty
        case .role(let name)?: store.core.matrix.rows.first { $0.role.name == name }?.role.declared == true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .retry?: store.send(.task)
        case .hiddenAgents?: store.send(.hiddenAgentsTapped)
        case .profile(let name)?: store.send(.profileTapped(name))
        case .addProfile?: store.send(.addProfileTapped)
        case .addRole?: store.send(.addRoleTapped)
        case .role(let name)?: store.send(.useForTapped(name))
        case .web?: if let link = store.core.webLink { UIApplication.shared.open(link) }
        default: break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, trailingSwipeActionsConfigurationForItemAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard store.core.canRestructure else { return nil }
        let actions: [UIContextualAction]
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile(let name)?:
            actions = [
                swipe(String(localized: "Delete"), style: .destructive) { .deleteProfileTapped(name) },
                swipe(String(localized: "Copy")) { .duplicateProfileTapped(name) },
                swipe(String(localized: "Rename")) { .renameProfileTapped(name) },
            ]
        case .role(let name)?:
            actions = [
                swipe(String(localized: "Delete"), style: .destructive) { .deleteRoleTapped(name) },
                swipe(String(localized: "Rename")) { .renameRoleTapped(name) },
            ]
        default:
            return nil
        }
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    private func swipe(
        _ title: String, style: UIContextualAction.Style = .normal, _ action: @escaping () -> DelegationSettings.Action
    ) -> UIContextualAction {
        let item = UIContextualAction(style: style, title: title) { [store] _, _, done in
            store.send(action())
            done(true)
        }
        if style == .normal { item.backgroundColor = .systemGray }
        return item
    }
}
