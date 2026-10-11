import ComposableArchitecture
import LeoFeatures
import UIKit
import UIKitNavigation

/// App settings: the notifications switch, why pushes might not arrive,
/// and a way to iOS Settings when the user turned Leo's notifications off.
final class SettingsViewController: UIViewController {
    private enum Item: Hashable {
        case notifications
        case openSystemSettings
        case problem(String)
    }

    private let store: StoreOf<PushNotifications>
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var footer = ""

    init(store: StoreOf<PushNotifications>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Settings")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        collectionView.accessibilityIdentifier = "settings.list"
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
            render(
                isEnabled: store.isEnabled, authorization: store.authorization,
                problems: Self.problems(relayError: store.relayError, daemonErrors: store.daemonErrors, daemons: Array(store.daemons))
            )
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.footerMode = .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = cell.defaultContentConfiguration()
            switch item {
            case .notifications:
                content.text = String(localized: "Notifications")
                content.image = UIImage(systemName: "bell.badge")
                let toggle = UISwitch()
                toggle.isOn = store.isEnabled
                toggle.accessibilityIdentifier = "settings.notifications"
                toggle.addAction(UIAction { [weak self, weak toggle] _ in
                    guard let toggle else { return }
                    self?.store.send(.toggled(toggle.isOn))
                }, for: .valueChanged)
                cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
            case .openSystemSettings:
                content.text = String(localized: "Open iOS Settings")
                content.textProperties.color = .tintColor
                cell.accessories = []
            case .problem(let message):
                content.text = message
                content.textProperties.color = .secondaryLabel
                content.textProperties.font = .preferredFont(forTextStyle: .footnote)
                content.image = UIImage(systemName: "exclamationmark.triangle.fill")
                content.imageProperties.tintColor = .systemOrange
                cell.accessories = []
            }
            cell.contentConfiguration = content
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = indexPath.section == 0 ? self?.footer : nil
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
        collectionView.delegate = self
    }

    private func render(isEnabled: Bool, authorization: PushAuthorization?, problems: [String]) {
        footer = Self.footer(isEnabled: isEnabled, authorization: authorization)
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems([.notifications])
        if isEnabled, authorization == .denied { snapshot.appendItems([.openSystemSettings]) }
        if isEnabled, !problems.isEmpty {
            snapshot.appendSections([1])
            snapshot.appendItems(problems.map(Item.problem))
        }
        snapshot.reconfigureItems([.notifications])
        snapshot.reloadSections([0])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private static func footer(isEnabled: Bool, authorization: PushAuthorization?) -> String {
        guard isEnabled else { return String(localized: "Your daemons won't notify this device.") }
        if authorization == .denied {
            return String(localized: "Notifications for Leo are off in iOS Settings, so agents that need you can't alert you.")
        }
        return String(localized: "Get a notification when an agent needs you. Its name and what it needs are encrypted on your daemon; only this device can read them.")
    }

    private static func problems(relayError: String?, daemonErrors: [String: String], daemons: [PairedDaemon]) -> [String] {
        let perDaemon = daemons.compactMap { daemon in daemonErrors[daemon.id].map { "\(daemon.name): \($0)" } }
        return [relayError].compactMap { $0 } + perDaemon
    }
}

extension SettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .openSystemSettings
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard dataSource.itemIdentifier(for: indexPath) == .openSystemSettings,
              let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
