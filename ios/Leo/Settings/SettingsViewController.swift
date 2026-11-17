import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// App settings: the notifications switch, why pushes might not arrive,
/// a way to iOS Settings when the user turned Leo's notifications off, and
/// the chat's live terminal default, and whether agents may use a browser
/// on this iPhone (B-305).
final class SettingsViewController: UIViewController {
    private enum Item: Hashable {
        case notifications
        case openSystemSettings
        /// Chat: when a thread shows its live terminal strip.
        case liveTerminal
        case statsStyle
        /// Settings > Agent Browser on This iPhone.
        case agentBrowser
        /// Identified by `PushProblem.id` (a daemon ID), never its text.
        case problem(PushProblem)
    }

    private static let chatSection = 1
    private static let browserSection = 3
    private static let headers = [chatSection: String(localized: "Chat"), browserSection: String(localized: "Browser")]

    private let store: StoreOf<PushNotifications>
    private let app: StoreOf<AppFeature>
    private var statsStyle = LeoStatsStyle.default
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var footer = ""
    private var liveTerminalMode = LiveTerminalMode.whileWorking
    private var isAgentBrowserEnabled = true

    init(app: StoreOf<AppFeature>) {
        self.app = app
        store = app.scope(state: \.push, action: \.push)
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
                isEnabled: store.isEnabled, authorization: store.authorization, problems: store.problems,
                statsStyle: app.fleet.statsStyle, liveTerminalMode: app.liveTerminalMode,
                isAgentBrowserEnabled: app.isAgentBrowserEnabled
            )
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { section, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.footerMode = .supplementary
            if Self.headers[section] != nil { configuration.headerMode = .supplementary }
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
            case .liveTerminal:
                content.text = String(localized: "Live terminal in chats")
                content.secondaryText = liveTerminalMode.title
                content.prefersSideBySideTextAndSecondaryText = true
                content.image = UIImage(systemName: "terminal")
                cell.accessibilityIdentifier = "settings.liveTerminal"
                let options = LiveTerminalMode.allCases.map { mode in
                    UIAction(title: mode.title, state: mode == liveTerminalMode ? .on : .off) { [weak self] _ in
                        self?.app.send(.liveTerminalModeChanged(mode))
                    }
                }
                cell.accessories = [.popUpMenu(UIMenu(children: options))]
            case .agentBrowser:
                content.text = String(localized: "Agent Browser on This iPhone")
                content.image = UIImage(systemName: "globe")
                let toggle = UISwitch()
                toggle.isOn = isAgentBrowserEnabled
                toggle.accessibilityIdentifier = "settings.agentBrowser"
                toggle.addAction(UIAction { [weak self, weak toggle] _ in
                    guard let toggle else { return }
                    self?.app.send(.agentBrowserToggled(toggle.isOn))
                }, for: .valueChanged)
                cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
            case .openSystemSettings:
                content.text = String(localized: "Open iOS Settings")
                content.textProperties.color = .tintColor
                cell.accessories = []
            case .statsStyle:
                content.text = String(localized: "Stats style")
                content.secondaryText = statsStyle.title
                content.prefersSideBySideTextAndSecondaryText = true
                content.image = UIImage(systemName: "chart.bar.fill")
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "settings.statsStyleRow"
            case .problem(let problem):
                content.text = problem.message
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
            content.text = switch indexPath.section {
            case 0: self?.footer
            case Self.chatSection: String(localized: "A strip under a chat's header shows the agent's last few terminal lines. While working shows it only while the agent is working. Each chat can hide or show it.")
            case Self.browserSection: String(localized: "While Leo is open, agents can browse here when no Mac running Leo takes their browser. Pages on an agent machine’s localhost can’t load on iPhone.")
            default: nil
            }
            view.contentConfiguration = content
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = Self.headers[indexPath.section]
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: kind == UICollectionView.elementKindSectionHeader ? headerRegistration : footerRegistration, for: indexPath
            )
        }
        collectionView.delegate = self
    }

    private func render(
        isEnabled: Bool, authorization: PushAuthorization?, problems: [PushProblem], statsStyle: LeoStatsStyle,
        liveTerminalMode: LiveTerminalMode, isAgentBrowserEnabled: Bool
    ) {
        self.statsStyle = statsStyle
        self.isAgentBrowserEnabled = isAgentBrowserEnabled
        self.liveTerminalMode = liveTerminalMode
        footer = Self.footer(isEnabled: isEnabled, authorization: authorization)
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems([.notifications])
        if isEnabled, authorization == .denied { snapshot.appendItems([.openSystemSettings]) }
        snapshot.appendSections([Self.chatSection])
        snapshot.appendItems([.liveTerminal])
        snapshot.appendSections([2])
        snapshot.appendItems([.statsStyle])
        snapshot.appendSections([Self.browserSection])
        snapshot.appendItems([.agentBrowser])
        // Off, these are daemons that haven't confirmed they stopped pushing.
        if !problems.isEmpty {
            snapshot.appendSections([Self.browserSection + 1])
            snapshot.appendItems(problems.map(Item.problem))
        }
        snapshot.reconfigureItems([.notifications, .liveTerminal, .statsStyle, .agentBrowser])
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

}

extension SettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        [.openSystemSettings, .statsStyle].contains(dataSource.itemIdentifier(for: indexPath))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if dataSource.itemIdentifier(for: indexPath) == .statsStyle {
            navigationController?.pushViewController(StatsStyleViewController(store: app), animated: true)
            return
        }
        guard dataSource.itemIdentifier(for: indexPath) == .openSystemSettings,
              let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
