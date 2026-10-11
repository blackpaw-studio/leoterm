import ComposableArchitecture
import LeoFeatures
import UIKit
import UIKitNavigation

/// One agent: live state, environment, actions, and what's coming next.
final class AgentDetailViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Int, CaseIterable {
        case header, claude, live, status, environment, actions
    }

    private enum Row: Hashable {
        case header
        case openInClaude
        case value(String)
        case switchEnvironment
        case command(Command)
        case terminal, files
    }

    private enum Command: Hashable {
        case interrupt, restart, start, stop

        var agentCommand: AgentCommand {
            switch self {
            case .interrupt: .interrupt
            case .restart: .restart
            case .start: .start
            case .stop: .stop
            }
        }
    }

    @UIBindable private var store: StoreOf<AgentDetail>
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var values: [String: (label: String, value: String, tint: UIColor?)] = [:]
    private var lastTappedIndexPath: IndexPath?

    init(store: StoreOf<AgentDetail>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "agent.detail"
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
        present(item: $store.scope(state: \.confirmation, action: \.confirmation)) { [weak self] store in
            let controller = UIAlertController(store: store)
            if let popover = controller.popoverPresentationController, let self {
                popover.sourceView = collectionView
                popover.sourceRect = lastTappedIndexPath.flatMap { self.collectionView.cellForItem(at: $0)?.frame }
                    ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            }
            return controller
        }

        navigationDestination(item: $store.scope(state: \.destination?.terminal, action: \.destination.terminal)) { store in
            TerminalViewController(store: store)
        }
        navigationDestination(item: $store.scope(state: \.destination?.files, action: \.destination.files)) { store in
            FilesViewController(store: store)
        }

        observe { [weak self] in
            guard let self else { return }
            render()
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            let section = Section(rawValue: index)
            let titled: Set<Section> = [.status, .environment, .actions]
            configuration.headerMode = section.map(titled.contains) == true ? .supplementary : .none
            let layout = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            if section == .header {
                // The identity block sits on the background, not in a card.
                layout.decorationItems = []
                layout.contentInsets.top = 0
            }
            return layout
        }
    }

    private func configureDataSource() {
        let header = UICollectionView.CellRegistration<AgentHeaderCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(name: store.agentName, daemon: store.daemon.name, agent: store.agent)
        }
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, row)
        }
        let sectionHeader = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = switch Section(rawValue: indexPath.section) {
            case .status: String(localized: "Status")
            case .environment: String(localized: "Environment")
            case .actions: String(localized: "Actions")
            default: nil
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            if case .header = item { return collectionView.dequeueConfiguredReusableCell(using: header, for: indexPath, item: item) }
            return collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: sectionHeader, for: indexPath)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, _ row: Row) {
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        switch row {
        case .header:
            return
        case .openInClaude:
            var content = UIListContentConfiguration.cell()
            content.image = UIImage(systemName: "arrow.up.forward.app.fill")
            content.text = String(localized: "Open in Claude")
            content.textProperties.color = .tintColor
            content.textProperties.font = .preferredFont(forTextStyle: .body).withWeight(.semibold)
            content.secondaryText = String(localized: "Continue the conversation with Remote Control")
            content.prefersSideBySideTextAndSecondaryText = false
            cell.contentConfiguration = content
            let arrow = UIImageView(image: UIImage(systemName: "arrow.up.right"))
            arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
            cell.accessories = [.customView(configuration: .init(customView: arrow, placement: .trailing(), tintColor: .tertiaryLabel))]
            cell.accessibilityIdentifier = "agent.openInClaude"
        case .value(let key):
            guard let value = values[key] else { return }
            var content = UIListContentConfiguration.valueCell()
            content.text = value.label
            content.secondaryText = value.value
            if let tint = value.tint { content.secondaryTextProperties.color = tint }
            content.prefersSideBySideTextAndSecondaryText = value.value.count < 28
            cell.contentConfiguration = content
        case .switchEnvironment:
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Switch Environment…")
            content.textProperties.color = store.isBusy ? .tertiaryLabel : .tintColor
            cell.contentConfiguration = content
            if store.isLoadingEnvironments { cell.accessories = [.spinner] }
            cell.accessibilityIdentifier = "agent.switchEnvironment"
        case .command(let command):
            var content = UIListContentConfiguration.cell()
            let (title, symbol, destructive) = switch command {
            case .interrupt: (String(localized: "Interrupt"), "hand.raised.fill", false)
            case .restart: (String(localized: "Restart"), "arrow.clockwise", false)
            case .start: (String(localized: "Start"), "play.fill", false)
            case .stop: (String(localized: "Stop"), "stop.fill", true)
            }
            content.text = title
            content.image = UIImage(systemName: symbol)
            let tint: UIColor = store.isBusy ? .tertiaryLabel : destructive ? .systemRed : .tintColor
            content.textProperties.color = tint
            content.imageProperties.tintColor = tint
            cell.contentConfiguration = content
            if store.inFlight == command.agentCommand { cell.accessories = [.spinner] }
            cell.accessibilityIdentifier = "agent.command.\(title.lowercased())"
        case .terminal:
            var content = UIListContentConfiguration.subtitleCell()
            content.text = String(localized: "Terminal")
            content.secondaryText = store.agent?.isStopped == true
                ? String(localized: "Stopped — start the agent to watch it")
                : String(localized: "Watch its tmux session live, read-only")
            content.image = UIImage(systemName: "apple.terminal")
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "agent.terminal"
        case .files:
            var content = UIListContentConfiguration.subtitleCell()
            content.text = String(localized: "Files")
            let count = store.files.count
            let unseen = store.unseenFileIDs.count
            content.secondaryText = switch (count, unseen) {
            case (0, _): String(localized: "Nothing surfaced yet")
            case (_, 0): String(localized: "\(count) surfaced")
            default: String(localized: "\(count) surfaced · \(unseen) new")
            }
            content.image = UIImage(systemName: "doc.on.doc")
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            var accessories: [UICellAccessory] = [.disclosureIndicator()]
            if unseen > 0 {
                let badge = BadgeView(text: "\(unseen)", tint: .tintColor)
                accessories.insert(.customView(configuration: .init(customView: badge, placement: .trailing())), at: 0)
            }
            cell.accessories = accessories
            cell.accessibilityIdentifier = "agent.files"
        }
    }

    private func render() {
        title = store.agentName
        guard let agent = store.agent else {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "questionmark.circle")
            configuration.text = String(localized: "Agent Not Found")
            configuration.secondaryText = String(localized: "\(store.agentName) is no longer on \(store.daemon.name).")
            contentUnavailableConfiguration = configuration
            dataSource.apply(NSDiffableDataSourceSnapshot())
            return
        }
        contentUnavailableConfiguration = nil

        var rows: [(key: String, label: String, value: String, tint: UIColor?)] = [
            ("state", String(localized: "State"), agent.statusText, nil),
        ]
        if agent.priority.needsAttention || agent.attention != nil {
            rows.append(("attention", String(localized: "Attention"), agent.attentionDetail ?? agent.badge.label, agent.priority.needsAttention ? agent.badge.tint : nil))
        }
        if let action = agent.currentActionText { rows.append(("action", String(localized: "Doing"), action, nil)) }
        if let template = agent.template { rows.append(("template", String(localized: "Template"), template, nil)) }
        if let harness = agent.harness { rows.append(("harness", String(localized: "Harness"), harness.capitalized, nil)) }
        rows.append(("connection", String(localized: "Daemon"), "\(store.daemon.name) · \(store.connection.label)", store.connection.isConnected ? nil : store.connection.tint))
        var environmentRows: [(key: String, label: String, value: String, tint: UIColor?)] = [
            ("environments", String(localized: "Environments"), agent.environmentText, nil),
        ]
        if let error = agent.environments?.error { environmentRows.append(("environmentError", String(localized: "Problem"), error, .systemRed)) }
        values = Dictionary((rows + environmentRows).map { ($0.key, (label: $0.label, value: $0.value, tint: $0.tint)) }, uniquingKeysWith: { $1 })

        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.header], toSection: .header)
        if agent.opensInClaude { snapshot.appendItems([.openInClaude], toSection: .claude) }
        snapshot.appendItems([.terminal, .files], toSection: .live)
        snapshot.appendItems(rows.map { .value($0.key) }, toSection: .status)
        snapshot.appendItems(environmentRows.map { .value($0.key) } + [.switchEnvironment], toSection: .environment)
        let commands: [Command] = agent.isStopped ? [.start] : [.interrupt, .restart, .stop]
        snapshot.appendItems(commands.map(Row.command), toSection: .actions)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .openInClaude, .terminal, .files: true
        case .switchEnvironment, .command: !store.isBusy
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        lastTappedIndexPath = indexPath
        switch dataSource.itemIdentifier(for: indexPath) {
        case .openInClaude: store.send(.openInClaudeButtonTapped)
        case .switchEnvironment: store.send(.switchEnvironmentButtonTapped)
        case .command(.interrupt): store.send(.interruptButtonTapped)
        case .command(.restart): store.send(.restartButtonTapped)
        case .command(.start): store.send(.startButtonTapped)
        case .command(.stop): store.send(.stopButtonTapped)
        case .terminal: store.send(.terminalButtonTapped)
        case .files: store.send(.filesButtonTapped)
        default: break
        }
    }
}

private extension UICellAccessory {
    /// A spinning activity indicator, for the row whose action is running.
    @MainActor static var spinner: UICellAccessory {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        return .customView(configuration: .init(customView: indicator, placement: .trailing()))
    }
}

/// The large agent identity at the top of the screen.
final class AgentHeaderCell: UICollectionViewCell {
    private let iconBackground = UIView()
    private let icon = UIImageView()
    private let nameLabel = UILabel()
    private let daemonLabel = UILabel()
    private let badgeContainer = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconBackground.layer.cornerRadius = 18
        iconBackground.layer.cornerCurve = .continuous
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        nameLabel.font = .preferredFont(forTextStyle: .title1).withWeight(.bold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        daemonLabel.font = .preferredFont(forTextStyle: .subheadline)
        daemonLabel.adjustsFontForContentSizeCategory = true
        daemonLabel.textColor = .secondaryLabel
        daemonLabel.textAlignment = .center
        badgeContainer.axis = .horizontal
        badgeContainer.alignment = .center

        for view in [iconBackground, icon] { view.translatesAutoresizingMaskIntoConstraints = false }
        iconBackground.addSubview(icon)
        let stack = UIStackView(arrangedSubviews: [iconBackground, nameLabel, daemonLabel, badgeContainer])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.setCustomSpacing(12, after: iconBackground)
        stack.setCustomSpacing(10, after: daemonLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            iconBackground.widthAnchor.constraint(equalToConstant: 72),
            iconBackground.heightAnchor.constraint(equalToConstant: 72),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, daemon: String, agent: Agent?) {
        let badge = agent?.badge ?? AgentBadge(.stopped)
        icon.image = UIImage(systemName: badge.symbol)
        icon.tintColor = badge.tint
        iconBackground.backgroundColor = badge.tint.withAlphaComponent(0.15)
        nameLabel.text = name
        daemonLabel.text = String(localized: "on \(daemon)")
        badgeContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        badgeContainer.addArrangedSubview(BadgeView(text: badge.label, tint: badge.tint))
        accessibilityElements = [nameLabel, daemonLabel, badgeContainer]
    }
}
