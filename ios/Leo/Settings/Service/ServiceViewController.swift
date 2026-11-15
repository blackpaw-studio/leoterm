import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// A machine's daemon: what it is running, the restarts and Reload Config,
/// and a live tail of its log. The restarts are the machine's
/// (`MachineRestart`), so one started here keeps going if this screen closes;
/// the log is read only while this screen is showing.
final class ServiceViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Int { case status, actions, log }

    private enum Item: Hashable {
        case message(String)
        case detail(String, String)
        case action(Action)
        case logPause
        case logCopy
        case logText
    }

    private enum Action: Hashable {
        case restartDaemon
        case restartAgents
        case reload

        var title: String {
            switch self {
            case .restartDaemon: String(localized: "Restart leo")
            case .restartAgents: String(localized: "Restart All Agents")
            case .reload: String(localized: "Reload Config")
            }
        }

        var symbol: String {
            switch self {
            case .restartDaemon: "arrow.clockwise"
            case .restartAgents: "arrow.triangle.2.circlepath"
            case .reload: "doc.badge.gearshape"
            }
        }
    }

    private static let logHeight: CGFloat = 320

    private let store: StoreOf<ServiceSettings>
    private let restart: StoreOf<MachineRestart>
    private let banners = ConfigBannerStack()
    private let logView = UITextView()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(store: StoreOf<ServiceSettings>, restart: StoreOf<MachineRestart>) {
        self.store = store
        self.restart = restart
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Service")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        configureLogView()
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "service.list"
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        store.send(.appeared)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        store.send(.disappeared)
    }

    private func configureLogView() {
        logView.isEditable = false
        logView.accessibilityIdentifier = "service.log"
        logView.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        logView.adjustsFontForContentSizeCategory = true
        logView.backgroundColor = .clear
        logView.alwaysBounceVertical = true
        logView.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: rendering

    private func render() {
        var notes: [ConfigBanner] = []
        if restart.isRestarting {
            let text = restart.isWaitingOnAgents ? MachineRestart.State.waitingOnAgentsText : "Restarting leo on \(restart.machine)…"
            notes.append(ConfigBanner(id: "restarting", style: .info, text: text))
        }
        if let logError = store.logError {
            notes.append(ConfigBanner(id: "log.error", style: .warning, text: "Log: \(logError)"))
        }
        banners.show(notes)

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.status])
        switch store.status {
        case .idle, .loading: snapshot.appendItems([.message(String(localized: "Loading…"))], toSection: .status)
        case .failed(let message): snapshot.appendItems([.message(message)], toSection: .status)
        case .loaded(let status): snapshot.appendItems(Self.details(of: status).map { .detail($0.0, $0.1) }, toSection: .status)
        }
        snapshot.appendSections([.actions, .log])
        snapshot.appendItems([.action(.restartDaemon), .action(.restartAgents), .action(.reload)], toSection: .actions)
        snapshot.appendItems([.logPause, .logCopy, .logText], toSection: .log)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { $0 != .logText })
        dataSource.apply(snapshot, animatingDifferences: false)

        let text = store.logText
        if logView.text != text {
            let wasAtEnd = logView.contentOffset.y + logView.bounds.height >= logView.contentSize.height - 8
            logView.text = text
            if wasAtEnd || logView.contentOffset == .zero { scrollLogToEnd() }
        }
    }

    private func scrollLogToEnd() {
        logView.layoutIfNeeded()
        let end = max(0, logView.contentSize.height - logView.bounds.height)
        logView.setContentOffset(CGPoint(x: 0, y: end), animated: false)
    }

    private static func details(of status: LeoServiceStatus) -> [(String, String)] {
        var rows = [
            (String(localized: "Version"), status.version),
            (String(localized: "Process"), String(status.pid)),
        ]
        if let started = status.startedAt {
            rows.append((String(localized: "Running since"), started.formatted(date: .abbreviated, time: .shortened)))
        }
        let running = status.runningAgentCount
        rows.append((String(localized: "Agents"), String(localized: "\(running) running")))
        if status.restartRequired.isNeeded {
            rows.append((String(localized: "Needs a restart"), Self.restartNeeded(status.restartRequired)))
        }
        return rows
    }

    private static func restartNeeded(_ required: LeoConfigRestartRequired) -> String {
        switch (required.service, required.agents) {
        case (true, true): String(localized: "leo and agents")
        case (true, false): String(localized: "leo")
        default: String(localized: "Agents")
        }
    }

    // MARK: layout and cells

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.valueCell()
            cell.accessories = []
            cell.accessibilityIdentifier = nil
            switch item {
            case .message(let text):
                content = .cell()
                content.text = text
                content.textProperties.color = .secondaryLabel
            case .detail(let title, let value):
                content.text = title
                content.secondaryText = value
                cell.accessibilityIdentifier = "service.detail.\(title)"
            case .action(let action):
                content = .cell()
                content.text = action.title
                content.image = UIImage(systemName: action.symbol)
                let isEnabled = !restart.isBusy
                content.textProperties.color = isEnabled ? cell.tintColor : .tertiaryLabel
                cell.accessibilityIdentifier = "service.action.\(action)"
            case .logPause:
                content = .cell()
                content.text = store.isPaused ? String(localized: "Resume Live Log") : String(localized: "Pause Live Log")
                content.image = UIImage(systemName: store.isPaused ? "play.circle" : "pause.circle")
                content.textProperties.color = cell.tintColor
                cell.accessibilityIdentifier = "service.log.pause"
            case .logCopy:
                content = .cell()
                content.text = String(localized: "Copy Log")
                content.image = UIImage(systemName: "doc.on.doc")
                content.textProperties.color = cell.tintColor
                cell.accessibilityIdentifier = "service.log.copy"
            case .logText:
                cell.contentConfiguration = nil
                cell.contentView.addSubview(logView)
                NSLayoutConstraint.activate([
                    logView.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                    logView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                    logView.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                    logView.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                    logView.heightAnchor.constraint(equalToConstant: Self.logHeight),
                ])
                return
            }
            cell.contentConfiguration = content
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .status?: String(localized: "Status")
            case .actions?: String(localized: "Actions")
            case .log?: String(localized: "Log")
            case nil: nil
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    // MARK: selection

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .action?: !restart.isBusy
        case .logPause?, .logCopy?: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .action(.restartDaemon)?: restart.send(.requested(.daemon))
        case .action(.restartAgents)?: restart.send(.requested(.agents))
        case .action(.reload)?: restart.send(.reloadRequested)
        case .logPause?: store.send(store.isPaused ? .resumeTapped : .pauseTapped)
        case .logCopy?: store.send(.copyTapped)
        default: break
        }
    }
}
