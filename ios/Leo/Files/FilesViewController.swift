import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// An agent's surfaced files, newest first: name, reason, path and age,
/// with a dot on the ones not yet opened.
final class FilesViewController: UIViewController, UICollectionViewDelegate {
    private enum Section { case files }

    @UIBindable private var store: StoreOf<Files>
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, LeoSurfacedFile.ID>!
    private let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    private let dateParsers: [ISO8601DateFormatter] = [.init(), {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()]

    init(store: StoreOf<Files>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Files")
        navigationItem.largeTitleDisplayMode = .never
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "files.list"
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
        navigationDestination(item: $store.scope(state: \.preview, action: \.preview)) { store in
            store.kind == .quickLook ? QuickLookPreviewController(store: store) : TextFileViewController(store: store)
        }

        observe { [weak self] in
            guard let self else { return }
            render()
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
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, LeoSurfacedFile.ID> { [weak self] cell, _, id in
            guard let self, let file = store.files.first(where: { $0.id == id }) else { return }
            configure(cell, file)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = String(localized: "Files \(self?.store.agentName ?? "") showed you with leo_surface_file. The daemon keeps the 20 most recent until it restarts.")
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, _ file: LeoSurfacedFile) {
        let isUnseen = store.unseenIDs.contains(file.id)
        let isUnavailable = store.unavailableIDs.contains(file.id)
        var content = UIListContentConfiguration.subtitleCell()
        content.image = UIImage(systemName: FilePreviewKind(fileName: file.path).symbolName)
        content.imageProperties.tintColor = isUnavailable ? .tertiaryLabel : .tintColor
        content.text = file.displayName
        content.textProperties.font = .preferredFont(forTextStyle: .body).withWeight(isUnseen ? .semibold : .regular)
        content.textProperties.color = isUnavailable ? .secondaryLabel : .label
        content.secondaryAttributedText = details(for: file, isUnavailable: isUnavailable)
        content.textToSecondaryTextVerticalPadding = 3
        cell.contentConfiguration = content

        var accessories: [UICellAccessory] = [
            .customView(configuration: .init(customView: UnreadDot(isVisible: isUnseen), placement: .leading(), reservedLayoutWidth: .custom(10))),
        ]
        if store.opening == file.id {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            accessories.append(.customView(configuration: .init(customView: spinner, placement: .trailing())))
        } else if let age = age(of: file) {
            let label = UILabel()
            label.text = age
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel
            accessories.append(.customView(configuration: .init(customView: label, placement: .trailing())))
        }
        cell.accessories = accessories
        cell.accessibilityIdentifier = "file.\(file.displayName)"
        cell.accessibilityValue = [isUnseen ? String(localized: "Unread") : nil, isUnavailable ? String(localized: "No longer available") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Reason (or "No longer available"), then the path as the agent gave
    /// it, in a quieter monospaced line.
    private func details(for file: LeoSurfacedFile, isUnavailable: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = UIFont.preferredFont(forTextStyle: .subheadline)
        if isUnavailable {
            result.append(NSAttributedString(string: String(localized: "No longer available") + "\n", attributes: [.font: body.withWeight(.medium), .foregroundColor: UIColor.systemOrange]))
        } else if let reason = file.displayReason {
            result.append(NSAttributedString(string: reason + "\n", attributes: [.font: body, .foregroundColor: UIColor.secondaryLabel]))
        }
        var path = LeoSFTPServerText.sanitized(file.path)
        if let line = file.line { path += ":\(line)" }
        let mono = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 11, weight: .regular))
        result.append(NSAttributedString(string: path, attributes: [.font: mono, .foregroundColor: UIColor.tertiaryLabel]))
        return result
    }

    private func age(of file: LeoSurfacedFile) -> String? {
        guard let at = file.at, let date = dateParsers.lazy.compactMap({ $0.date(from: at) }).first else { return nil }
        return ageFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func render() {
        if store.files.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "doc.on.doc")
            configuration.text = String(localized: "No Files Yet")
            configuration.secondaryText = String(localized: "When \(store.agentName) surfaces a file for you to look at, it appears here.")
            contentUnavailableConfiguration = configuration
        } else {
            contentUnavailableConfiguration = nil
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, LeoSurfacedFile.ID>()
        if !store.files.isEmpty {
            snapshot.appendSections([.files])
            snapshot.appendItems(store.files.map(\.id))
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        store.opening == nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        store.send(.fileTapped(id))
    }
}

/// The unread marker: a small tinted dot, or empty space so rows align.
private final class UnreadDot: UIView {
    init(isVisible: Bool) {
        super.init(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        backgroundColor = isVisible ? .tintColor : .clear
        layer.cornerRadius = 5
        isAccessibilityElement = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 10), heightAnchor.constraint(equalToConstant: 10)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension FilePreviewKind {
    var symbolName: String {
        switch self {
        case .markdown: "doc.richtext"
        case .text: "doc.plaintext"
        case .quickLook: "doc.viewfinder"
        case .unknown: "doc"
        }
    }
}
