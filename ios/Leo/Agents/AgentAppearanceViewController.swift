import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// The Appearance sheet for one agent (long press > Appearance): where each
/// value comes from, None and the palette, and an emoji search and grid.
/// Each pick is one write (see `AgentAppearance`).
final class AgentAppearanceViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable {
        case info, noColor, colors, noEmoji
        case emoji(String)
    }

    private enum Item: Hashable {
        case emojiSource, colorSource, error, reset
        case noEmoji, noColor
        case swatch(LeoAppearanceColor)
        case emoji(section: String, emoji: String)

        /// Rows that start a write.
        var isPick: Bool {
            switch self {
            case .reset, .noEmoji, .noColor: true
            default: false
            }
        }
    }

    /// The picks dim while a write is in flight; only one runs at a time.
    private static let savingAlpha: CGFloat = 0.4
    private static let catalog = LeoEmojiCatalog.standard
    private static let frequentTitle = String(localized: "Frequently Used")
    private static let resultsTitle = String(localized: "Results")

    @UIBindable private var store: StoreOf<AgentAppearance>
    private let searchField = UISearchTextField()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(store: StoreOf<AgentAppearance>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Appearance")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.subtitle = store.agentName
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.store.send(.doneTapped) }
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "appearance.done"

        searchField.placeholder = String(localized: "Search emoji")
        searchField.accessibilityIdentifier = "appearance.search"
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .search
        searchField.addAction(UIAction { [weak self] _ in self?.searchField.resignFirstResponder() }, for: .primaryActionTriggered)
        bind(searchField)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "appearance.list"
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .onDrag
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchField)
        view.addSubview(collectionView)
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()

        var previous: (appearance: LeoAgentAppearance?, isSaving: Bool) = (nil, false)
        observe { [weak self] in
            guard let self else { return }
            render(previousAppearance: previous.appearance, isSavingChanged: previous.isSaving != store.isSaving)
            previous = (store.appearance, store.isSaving)
        }
        store.send(.task)
    }

    private func bind(_ field: UISearchTextField) {
        field.bind(text: $store.query)
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = dataSource.sectionIdentifier(for: index) else { return nil }
            switch section {
            case .info, .noColor, .noEmoji:
                var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                configuration.headerMode = .none
                configuration.backgroundColor = .clear
                return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            case .colors:
                return Self.grid(columns: 5, spacing: 4, height: 48, header: false)
            case .emoji:
                return Self.grid(columns: 7, spacing: 2, height: 48, header: true)
            }
        }
    }

    private static func grid(columns: Int, spacing: CGFloat, height: CGFloat, header: Bool) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .absolute(height)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)), repeatingSubitem: item, count: columns)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.contentInsets = .init(top: 4, leading: 12, bottom: 12, trailing: 12)
        if header {
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(28))
            section.boundarySupplementaryItems = [
                NSCollectionLayoutBoundarySupplementaryItem(layoutSize: size, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            ]
        }
        return section
    }

    // MARK: Cells

    private func configureDataSource() {
        let rows = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.valueCell()
            var accessories: [UICellAccessory] = []
            switch item {
            case .emojiSource:
                content.text = String(localized: "Emoji")
                content.secondaryText = store.emojiSourceText
            case .colorSource:
                content.text = String(localized: "Color")
                content.secondaryText = store.colorSourceText
            case .error:
                content = .cell()
                content.text = store.error
                content.textProperties.color = .systemRed
                content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            case .reset:
                content = .cell()
                content.text = String(localized: "Reset to Rules")
                content.textProperties.color = .tintColor
            case .noColor:
                content = .cell()
                content.text = store.noneColorLabel
                if store.colorPick == nil { accessories = [.checkmark()] }
            case .noEmoji:
                content = .cell()
                content.text = String(localized: "No emoji")
                if store.appearance?.emojiSource != .manual { accessories = [.checkmark()] }
            case .swatch, .emoji:
                break
            }
            content.secondaryTextProperties.numberOfLines = 0
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessories = accessories
            cell.backgroundConfiguration = .listCell()
            if item.isPick { cell.contentView.alpha = store.isSaving ? Self.savingAlpha : 1 }
        }
        let swatch = UICollectionView.CellRegistration<SwatchCell, LeoAppearanceColor> { [weak self] cell, _, color in
            cell.configure(color: color, isPicked: self?.store.colorPick == color)
            cell.contentView.alpha = self?.store.isSaving == true ? Self.savingAlpha : 1
        }
        let emoji = UICollectionView.CellRegistration<EmojiCell, String> { [weak self] cell, _, emoji in
            guard let self, let entry = Self.catalog.entry(for: emoji) else { return }
            cell.configure(entry: entry, isPicked: store.appearance?.emoji == emoji)
            cell.contentView.alpha = store.isSaving ? Self.savingAlpha : 1
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            guard let self, case .emoji(let title) = dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = UIListContentConfiguration.groupedHeader()
            content.text = title
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .swatch(let color): collectionView.dequeueConfiguredReusableCell(using: swatch, for: indexPath, item: color)
            case .emoji(_, let value): collectionView.dequeueConfiguredReusableCell(using: emoji, for: indexPath, item: value)
            default: collectionView.dequeueConfiguredReusableCell(using: rows, for: indexPath, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    // MARK: Rendering

    private func render(previousAppearance: LeoAgentAppearance?, isSavingChanged: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.info, .noColor, .colors, .noEmoji])
        snapshot.appendItems([.emojiSource, .colorSource] + (store.error == nil ? [] : [Item.error]) + (store.canReset ? [Item.reset] : []), toSection: .info)
        snapshot.appendItems([.noColor], toSection: .noColor)
        snapshot.appendItems(LeoAppearanceColor.allCases.map(Item.swatch), toSection: .colors)
        snapshot.appendItems([.noEmoji], toSection: .noEmoji)
        for (title, entries) in emojiSections() {
            snapshot.appendSections([.emoji(title)])
            snapshot.appendItems(entries.map { Item.emoji(section: title, emoji: $0.emoji) }, toSection: .emoji(title))
        }
        let touched = Set([previousAppearance?.emoji, store.appearance?.emoji].compactMap { $0 })
        let reconfigured = snapshot.itemIdentifiers.filter { item in
            switch item {
            case .emoji(_, let emoji): isSavingChanged || touched.contains(emoji)
            default: true
            }
        }
        snapshot.reconfigureItems(reconfigured)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func emojiSections() -> [(String, [LeoEmojiEntry])] {
        let query = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return [(Self.resultsTitle, Self.catalog.search(query))] }
        let frequent = Self.catalog.frequent(recent: store.recents)
        return (frequent.isEmpty ? [] : [(Self.frequentTitle, frequent)]) + Self.catalog.groups.map { ($0.name, $0.entries) }
    }

    // MARK: Selection

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .emojiSource, .colorSource, .error, nil: false
        default: !store.isSaving
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .reset: store.send(.resetTapped)
        case .noColor: store.send(.colorPicked(nil))
        case .noEmoji: store.send(.emojiCleared)
        case .swatch(let color): store.send(.colorPicked(color))
        case .emoji(_, let emoji): store.send(.emojiPicked(emoji))
        case .emojiSource, .colorSource, .error, nil: break
        }
    }
}
